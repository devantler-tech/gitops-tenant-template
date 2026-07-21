#!/usr/bin/env sh
# Pin the Platform network-floor validation into the scaffold workflow and
# tenant-ownership boundary so a generated-policy drift cannot pass silently.
set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
workflow=$repo_root/.github/workflows/validate-scaffold.yaml
runtime=$repo_root/scripts/platform-network-floor.test.sh
readme=$repo_root/README.md
template_sync_ignore=$repo_root/.templatesyncignore

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

validate_contract() {
	workflow_file=$1
	runtime_file=$2
	readme_file=$3
	ignore_file=$4

	[ -f "$runtime_file" ] || fail "Platform network-floor runtime is missing"

	# The Platform source must be live main, read-only, and limited to the policy
	# catalogue that supplies the generated floor.
	# shellcheck disable=SC2016
	yq eval -e '
		[.jobs.admissibility.steps[]
			| select(.with.repository == "devantler-tech/platform")
			| select(
				.uses == "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0"
				and .with.path == ".platform"
				and .with."persist-credentials" == false
				and ((.with."sparse-checkout" | split("\n") | map(select(. != "")))
					| contains(["k8s/bases/infrastructure/cluster-policies"]))
			)
		] | length == 1
	' "$workflow_file" >/dev/null ||
		fail "Platform network-floor checkout is missing or mutable"
	# shellcheck disable=SC2016
	yq eval -e '
		[.jobs.admissibility.steps[] | select(
			(.run // "") == "sh scripts/platform-network-floor.test.sh"
			and ((has("if") or has("continue-on-error")) | not)
		)] | length == 1
	' "$workflow_file" >/dev/null ||
		fail "Platform network-floor runtime step is missing or conditional"
	# shellcheck disable=SC2016
	yq eval -e '
		[.jobs."validate-scaffold".steps[] | select(
			(.run // "") == "sh scripts/platform-network-floor-contract.test.sh"
			and ((has("if") or has("continue-on-error")) | not)
		)] | length == 1
	' "$workflow_file" >/dev/null ||
		fail "Platform network-floor contract step is missing or conditional"

	for needle in \
		'add-default-deny.yaml' \
		'generate-default-deny' \
		'generate-allow-dns' \
		'generate-default-deny-networkpolicy' \
		'ingressDeny' \
		'egressDeny' \
		'fromEntities' \
		'toEntities' \
		'kube-apiserver' \
		'request.object.metadata.name' \
		'UDP' \
		'TCP' \
		'validate_network_floor' \
		'run_platform_mutation' \
		'run_scaffold_mutation'
	do
		grep -Fq -- "$needle" "$runtime_file" ||
			fail "Platform network-floor runtime lacks: $needle"
	done

	owned_ignore_block=$(awk '
		/^\*\*Yours \(list these in `\.templatesyncignore`\):\*\*$/ { found = 1; next }
		found && /^```gitignore$/ { inside = 1; next }
		inside && /^```$/ { exit }
		inside { print }
	' "$readme_file")
	for scaffold_path in \
		'scripts/platform-network-floor.test.sh' \
		'scripts/platform-network-floor-contract.test.sh'
	do
		printf '%s\n' "$owned_ignore_block" | grep -Fxq -- "$scaffold_path" ||
			fail "README ignore example lacks: $scaffold_path"
		grep -Fxq -- "$scaffold_path" "$ignore_file" ||
			fail ".templatesyncignore lacks: $scaffold_path"
	done

	# shellcheck disable=SC2016
	grep -Fq '`scripts/platform-network-floor*.test.sh`' "$readme_file" ||
		fail "README ownership table lacks the Platform network-floor contract"
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 5 ] ||
		fail "usage: $0 --validate <workflow> <runtime> <readme> <ignore>"
	validate_contract "$2" "$3" "$4" "$5"
	exit 0
fi

validate_contract "$workflow" "$runtime" "$readme" "$template_sync_ignore"

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT

run_mutation() {
	description=$1
	workflow_mutation=$2
	runtime_mutation=$3
	readme_mutation=${4:-}
	ignore_mutation=${5:-}

	cp "$workflow" "$mutation_dir/workflow.yaml"
	cp "$runtime" "$mutation_dir/runtime.sh"
	cp "$readme" "$mutation_dir/README.md"
	cp "$template_sync_ignore" "$mutation_dir/templatesyncignore"

	if [ -n "$workflow_mutation" ]; then
		yq eval "$workflow_mutation" "$mutation_dir/workflow.yaml" > "$mutation_dir/mutant.yaml"
		mv "$mutation_dir/mutant.yaml" "$mutation_dir/workflow.yaml"
	fi
	if [ -n "$runtime_mutation" ]; then
		sed "$runtime_mutation" "$mutation_dir/runtime.sh" > "$mutation_dir/mutant.sh"
		mv "$mutation_dir/mutant.sh" "$mutation_dir/runtime.sh"
	fi
	if [ -n "$readme_mutation" ]; then
		sed "$readme_mutation" "$mutation_dir/README.md" > "$mutation_dir/mutant.md"
		mv "$mutation_dir/mutant.md" "$mutation_dir/README.md"
	fi
	if [ -n "$ignore_mutation" ]; then
		sed "$ignore_mutation" "$mutation_dir/templatesyncignore" > "$mutation_dir/mutant.ignore"
		mv "$mutation_dir/mutant.ignore" "$mutation_dir/templatesyncignore"
	fi

	if (validate_contract \
		"$mutation_dir/workflow.yaml" \
		"$mutation_dir/runtime.sh" \
		"$mutation_dir/README.md" \
		"$mutation_dir/templatesyncignore") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_mutation "live network-floor invocation removed" \
	'del(.jobs.admissibility.steps[] | select(.run == "sh scripts/platform-network-floor.test.sh"))' ''
run_mutation "live network-floor invocation made conditional" \
	'(.jobs.admissibility.steps[] | select(.run == "sh scripts/platform-network-floor.test.sh")).if = "false"' ''
run_mutation "contract invocation removed" \
	'del(.jobs."validate-scaffold".steps[] | select(.run == "sh scripts/platform-network-floor-contract.test.sh"))' ''
run_mutation "Platform policy checkout removed" \
	'(.jobs.admissibility.steps[] | select(.with.repository == "devantler-tech/platform").with."sparse-checkout") |= sub("k8s/bases/infrastructure/cluster-policies\\n"; "")' ''
run_mutation "deny-shape validation removed" '' '/ingressDeny/d'
run_mutation "Platform mutation controls removed" '' '/run_platform_mutation/d'
run_mutation "README runtime ownership marker removed" '' '' \
	'/^scripts\/platform-network-floor\.test\.sh$/d'
run_mutation ".templatesyncignore runtime marker removed" '' '' '' \
	'/^scripts\/platform-network-floor\.test\.sh$/d'

echo "PASS: Platform network-floor contract (happy path + 8 safety mutations)"
