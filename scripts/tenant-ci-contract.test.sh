#!/usr/bin/env sh
# Pin the delivery inputs that every adopted tenant's default PR gate validates.
set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
ci_workflow=$repo_root/.github/workflows/ci.yaml
scaffold_workflow=$repo_root/.github/workflows/validate-scaffold.yaml
readme=$repo_root/README.md
agents=$repo_root/AGENTS.md
template_sync_ignore=$repo_root/.templatesyncignore

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

validate_contract() {
	ci_file=$1
	scaffold_file=$2
	readme_file=$3
	agents_file=$4
	ignore_file=$5

	assert_ci() {
		description=$1
		expression=$2
		if ! yq eval -e "$expression" "$ci_file" >/dev/null 2>&1; then
			fail "default CI contract: $description"
		fi
	}

	assert_ci "workflow permissions must default to none" \
		'(.permissions | length) == 0'
	assert_ci "delivery job must retain its stable identity" \
		'.jobs."delivery-inputs".name == "Delivery inputs"'
	assert_ci "delivery job must use the hosted runner" \
		'.jobs."delivery-inputs"."runs-on" == "ubuntu-latest"'
	assert_ci "delivery job must be unconditional" \
		'(.jobs."delivery-inputs" | has("if") | not)'
	assert_ci "delivery job must have no dependencies" \
		'(.jobs."delivery-inputs" | has("needs") | not)'
	assert_ci "delivery job must fail closed" \
		'(.jobs."delivery-inputs" | has("continue-on-error") | not)'
	assert_ci "delivery job must not access an environment" \
		'(.jobs."delivery-inputs" | has("environment") | not)'
	assert_ci "delivery job must have one permission" \
		'(.jobs."delivery-inputs".permissions | length) == 1'
	assert_ci "delivery job must have contents-read only" \
		'.jobs."delivery-inputs".permissions.contents == "read"'
	assert_ci "delivery steps must fail closed" '
		[.jobs."delivery-inputs".steps[]
		| select(has("if") or has("continue-on-error"))]
		| length == 0
	'
	assert_ci "runner hardening must stay pinned" '
		[.jobs."delivery-inputs".steps[] | select(
			.uses == "step-security/harden-runner@bf7454d06d71f1098171f2acdf0cd4708d7b5920"
			and .with."egress-policy" == "audit"
		)] | length == 1
	'
	assert_ci "delivery job must have exactly one checkout" '
		[.jobs."delivery-inputs".steps[] | select(
			(.uses // "") | test("^actions/checkout@")
		)] | length == 1
	'
	assert_ci "checkout must stay pinned and credential-free" '
		[.jobs."delivery-inputs".steps[] | select(
			.uses == "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0"
			and .with."persist-credentials" == false
		)] | length == 1
	'
	assert_ci "tenant image build is missing" '
		[.jobs."delivery-inputs".steps[] | select(
			(.run // "") == "docker build --tag tenant-delivery-check ."
		)] | length == 1
	'
	assert_ci "tenant manifest render is missing" '
		[.jobs."delivery-inputs".steps[] | select(
			(.run // "") == "kubectl kustomize deploy/ >/dev/null"
		)] | length == 1
	'
	assert_ci "required-check aggregate must have two dependencies" \
		'(.jobs."ci-required-checks".needs | length) == 2'
	assert_ci "required-check aggregate must depend on both jobs" '
		[.jobs."ci-required-checks".needs[] | select(
			. == "delivery-inputs" or . == "example"
		)] | length == 2
	'
	# shellcheck disable=SC2016
	assert_ci "required-check aggregate must run after every result" \
		'.jobs."ci-required-checks".if == "${{ always() }}"'
	assert_ci "required-check aggregate must fail closed" \
		'(.jobs."ci-required-checks" | has("continue-on-error") | not)'
	assert_ci "required-check aggregate must consume both results" '
		[.jobs."ci-required-checks".steps[] | select(
			.uses == "devantler-tech/actions/aggregate-job-checks@47f0d9b632581a613963a2d25c243713f24c32a0"
			and ((.with."job-results" | split("needs.delivery-inputs.result") | length) == 2)
			and ((.with."job-results" | split("needs.example.result") | length) == 2)
		)] | length == 1
	'

	# shellcheck disable=SC2016
	if ! yq eval -e '
		.jobs."validate-scaffold".steps
		| map(select(
			(.run // "") == "sh scripts/tenant-ci-contract.test.sh"
			and ((has("if") or has("continue-on-error")) | not)
		))
		| length == 1
	' "$scaffold_file" >/dev/null; then
		fail "template validation does not exercise the tenant CI contract"
	fi

	# Backticks are documentation literals, never shell expressions.
	# shellcheck disable=SC2016
	grep -Fq 'Default PR CI always builds the tenant image and renders `deploy/`' \
		"$readme_file" || fail "README omits the delivery-input invariant"
	# shellcheck disable=SC2016
	tr '\n' ' ' < "$agents_file" |
		grep -Fq 'build the tenant image and render `deploy/` before merge' ||
		fail "scaffolded validation guidance omits the delivery-input invariant"
	grep -Fxq 'scripts/tenant-ci-contract.test.sh' "$ignore_file" ||
		fail ".templatesyncignore lacks the scaffold-only tenant CI contract"
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 6 ] ||
		fail "usage: $0 --validate <ci> <scaffold> <README> <AGENTS> <templatesyncignore>"
	validate_contract "$2" "$3" "$4" "$5" "$6"
	exit 0
fi

validate_contract \
	"$ci_workflow" \
	"$scaffold_workflow" \
	"$readme" \
	"$agents" \
	"$template_sync_ignore"

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT

run_mutation() {
	description=$1
	ci_mutation=${2:-}
	scaffold_mutation=${3:-}
	readme_mutation=${4:-}
	agents_mutation=${5:-}
	ignore_mutation=${6:-}

	cp "$ci_workflow" "$mutation_dir/ci.yaml"
	cp "$scaffold_workflow" "$mutation_dir/scaffold.yaml"
	cp "$readme" "$mutation_dir/README.md"
	cp "$agents" "$mutation_dir/AGENTS.md"
	cp "$template_sync_ignore" "$mutation_dir/templatesyncignore"

	if [ -n "$ci_mutation" ]; then
		yq eval "$ci_mutation" "$mutation_dir/ci.yaml" > "$mutation_dir/mutant.yaml"
		mv "$mutation_dir/mutant.yaml" "$mutation_dir/ci.yaml"
	fi
	if [ -n "$scaffold_mutation" ]; then
		yq eval "$scaffold_mutation" "$mutation_dir/scaffold.yaml" > "$mutation_dir/mutant.yaml"
		mv "$mutation_dir/mutant.yaml" "$mutation_dir/scaffold.yaml"
	fi
	if [ -n "$readme_mutation" ]; then
		sed "$readme_mutation" "$mutation_dir/README.md" > "$mutation_dir/mutant.md"
		mv "$mutation_dir/mutant.md" "$mutation_dir/README.md"
	fi
	if [ -n "$agents_mutation" ]; then
		sed "$agents_mutation" "$mutation_dir/AGENTS.md" > "$mutation_dir/mutant.md"
		mv "$mutation_dir/mutant.md" "$mutation_dir/AGENTS.md"
	fi
	if [ -n "$ignore_mutation" ]; then
		sed "$ignore_mutation" "$mutation_dir/templatesyncignore" > "$mutation_dir/mutant.ignore"
		mv "$mutation_dir/mutant.ignore" "$mutation_dir/templatesyncignore"
	fi

	if (validate_contract \
		"$mutation_dir/ci.yaml" \
		"$mutation_dir/scaffold.yaml" \
		"$mutation_dir/README.md" \
		"$mutation_dir/AGENTS.md" \
		"$mutation_dir/templatesyncignore") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_mutation "delivery job removed" \
	'del(.jobs."delivery-inputs")'
run_mutation "container build removed" \
	'del(.jobs."delivery-inputs".steps[] | select((.run // "") == "docker build --tag tenant-delivery-check ."))'
run_mutation "manifest render removed" \
	'del(.jobs."delivery-inputs".steps[] | select((.run // "") == "kubectl kustomize deploy/ >/dev/null"))'
run_mutation "checkout credentials retained" \
	'.jobs."delivery-inputs".steps[] |= (select(.uses == "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0").with."persist-credentials" = true)'
run_mutation "second mutable checkout added" \
	'.jobs."delivery-inputs".steps += [{"name": "Unsafe checkout", "uses": "actions/checkout@main"}]'
run_mutation "job permissions broadened" \
	'.jobs."delivery-inputs".permissions.packages = "write"'
run_mutation "delivery dependency removed from aggregate" \
	'.jobs."ci-required-checks".needs = ["example"]'
# The GitHub expression is mutation data, not a shell expansion.
# shellcheck disable=SC2016
run_mutation "delivery result removed from aggregate" \
	'.jobs."ci-required-checks".steps[0].with."job-results" = "${{ needs.example.result }}"'
run_mutation "delivery job made conditional" \
	'.jobs."delivery-inputs".if = "github.actor == '\''devantler'\''"'
run_mutation "contract invocation removed" '' \
	'del(.jobs."validate-scaffold".steps[] | select((.run // "") == "sh scripts/tenant-ci-contract.test.sh"))'
run_mutation "README invariant removed" '' '' \
	'/Default PR CI always builds the tenant image/d'
run_mutation "scaffolded validation invariant removed" '' '' '' \
	'/build the tenant image/d'
run_mutation "contract ignore removed" '' '' '' '' \
	'/^scripts\/tenant-ci-contract\.test\.sh$/d'

echo "PASS: tenant CI contract (happy path + 13 safety mutations)"
