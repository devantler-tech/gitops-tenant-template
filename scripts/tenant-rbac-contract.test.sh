#!/usr/bin/env sh
# Pin the live Platform tenant-RBAC gate copied by this template.
set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
workflow=$repo_root/.github/workflows/validate-scaffold.yaml
runtime=$repo_root/scripts/tenant-rbac.test.sh
pod_security_runtime=$repo_root/scripts/pod-security-admission.test.sh
readme=$repo_root/README.md

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

validate_contract() {
	workflow_file=$1
	runtime_file=$2
	pod_security_file=$3
	readme_file=$4

	[ -f "$runtime_file" ] || fail "tenant RBAC runtime is missing"

	expected_if=$(printf '%s' \
		"github.repository == 'devantler-tech/gitops-tenant-template'")
	export expected_if
	# shellcheck disable=SC2016
	if ! yq eval -e '
		.jobs."pod-security-admission" as $job
		| ($job.if == strenv(expected_if)
		and $job.needs == null
		and ($job | has("continue-on-error") | not)
		and ([.jobs."validate-scaffold".steps[] | select(
			(.run // "") == "sh scripts/tenant-rbac-contract.test.sh"
			and ((has("if") or has("continue-on-error")) | not)
		)] | length == 1)
		and ([$job.steps[] | select(has("if") or has("continue-on-error"))] | length == 0)
		and ([$job.steps[] | select(
			.uses == "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0"
			and .with.repository == "devantler-tech/platform"
			and .with.path == ".platform"
			and .with."sparse-checkout" == "k8s/bases/infrastructure/cluster-roles"
			and .with."persist-credentials" == false
		)] | length == 1))
	' "$workflow_file" >/dev/null; then
		fail "tenant RBAC workflow checkout is missing, conditional, or mutable"
	fi

	# The contract intentionally matches the literal runtime expression.
	# shellcheck disable=SC2016
	grep -Fq 'sh "$repo_root/scripts/tenant-rbac.test.sh"' "$pod_security_file" ||
		fail "Pod Security runtime does not exercise tenant RBAC before cluster cleanup"

	for needle in \
		'tenant-edit.yaml' \
		'tenant-base-edit.yaml' \
		'cilium-tenant-edit.yaml' \
		'cnpg-tenant-edit.yaml' \
		'external-secrets-tenant-edit.yaml' \
		'gateway-tenant-edit.yaml' \
		'kubectl auth can-i' \
		'authorization.k8s.io/v1' \
		'kind: "SubjectAccessReview"' \
		'system:serviceaccount:tenant-rbac-test:tenant-reconciler' \
		'get list watch create patch update delete' \
		'deployments.apps' \
		'services' \
		'poddisruptionbudgets.policy' \
		'ciliumnetworkpolicies.cilium.io' \
		'externalsecrets.external-secrets.io' \
		'secretstores.external-secrets.io' \
		'httproutes.gateway.networking.k8s.io' \
		'clusters.postgresql.cnpg.io' \
		'clustersecretstores.external-secrets.io' \
		'ciliumclusterwidenetworkpolicies.cilium.io' \
		'namespaces' \
		'clusterroles.rbac.authorization.k8s.io' \
		'pods/exec'
	do
		grep -Fq -- "$needle" "$runtime_file" ||
			fail "tenant RBAC runtime lacks: $needle"
	done

	owned_ignore_block=$(awk '
		/^\*\*Yours \(list these in `\.templatesyncignore`\):\*\*$/ { found = 1; next }
		found && /^```gitignore$/ { inside = 1; next }
		inside && /^```$/ { exit }
		inside { print }
	' "$readme_file")
	for scaffold_path in \
		'scripts/tenant-rbac.test.sh' \
		'scripts/tenant-rbac-contract.test.sh'
	do
		printf '%s\n' "$owned_ignore_block" | grep -Fxq -- "$scaffold_path" ||
			fail "README ignore example lacks: $scaffold_path"
	done
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 5 ] ||
		fail "usage: $0 --validate <workflow> <runtime> <pod-security-runtime> <readme>"
	validate_contract "$2" "$3" "$4" "$5"
	exit 0
fi

validate_contract "$workflow" "$runtime" "$pod_security_runtime" "$readme"

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT

run_mutation() {
	description=$1
	workflow_mutation=$2
	runtime_mutation=$3
	pod_security_mutation=$4
	readme_mutation=${5:-}

	cp "$workflow" "$mutation_dir/workflow.yaml"
	cp "$runtime" "$mutation_dir/runtime.sh"
	cp "$pod_security_runtime" "$mutation_dir/pod-security.sh"
	cp "$readme" "$mutation_dir/README.md"

	if [ -n "$workflow_mutation" ]; then
		yq eval "$workflow_mutation" "$mutation_dir/workflow.yaml" > "$mutation_dir/mutant.yaml"
		mv "$mutation_dir/mutant.yaml" "$mutation_dir/workflow.yaml"
	fi
	if [ -n "$runtime_mutation" ]; then
		sed "$runtime_mutation" "$mutation_dir/runtime.sh" > "$mutation_dir/mutant.sh"
		mv "$mutation_dir/mutant.sh" "$mutation_dir/runtime.sh"
	fi
	if [ -n "$pod_security_mutation" ]; then
		sed "$pod_security_mutation" "$mutation_dir/pod-security.sh" > "$mutation_dir/mutant.sh"
		mv "$mutation_dir/mutant.sh" "$mutation_dir/pod-security.sh"
	fi
	if [ -n "$readme_mutation" ]; then
		sed "$readme_mutation" "$mutation_dir/README.md" > "$mutation_dir/mutant.md"
		mv "$mutation_dir/mutant.md" "$mutation_dir/README.md"
	fi

	if (validate_contract \
		"$mutation_dir/workflow.yaml" \
		"$mutation_dir/runtime.sh" \
		"$mutation_dir/pod-security.sh" \
		"$mutation_dir/README.md") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_mutation "Platform checkout removed" \
	'del(.jobs."pod-security-admission".steps[] | select(.with.repository == "devantler-tech/platform"))' '' ''
run_mutation "contract invocation removed" \
	'del(.jobs."validate-scaffold".steps[] | select(.run == "sh scripts/tenant-rbac-contract.test.sh"))' '' ''
run_mutation "cluster-role checkout widened" \
	'.jobs."pod-security-admission".steps[] |= (select(.with.repository == "devantler-tech/platform").with."sparse-checkout" = "k8s/bases/infrastructure")' '' ''
run_mutation "aggregate role fragment removed" '' \
	'/tenant-base-edit\.yaml/d' ''
run_mutation "required verb removed" '' \
	's/get list watch create patch update delete/get list watch create patch update/' ''
run_mutation "resource mapping removed" '' \
	'/httproutes\.gateway\.networking\.k8s\.io/d' ''
run_mutation "authorization invocation removed" '' \
	'/kind: "SubjectAccessReview"/d' ''
run_mutation "RBAC runtime call removed" '' '' \
	'/tenant-rbac\.test\.sh/d'
run_mutation "denial boundary removed" '' \
	'/pods\/exec/d' ''
run_mutation "documented ignore removed" '' '' '' \
	'/^scripts\/tenant-rbac\.test\.sh$/d'

echo "PASS: tenant RBAC contract (happy path + 10 safety mutations)"
