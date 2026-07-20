#!/usr/bin/env sh
# Verify that Platform main still supplies the namespace and Flux impersonation
# envelope assumed by this template's workload-level validation.
set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

validate_platform() {
	platform_root=$1
	rgd=$platform_root/k8s/bases/infrastructure/resource-graph-definitions/tenant/resource-graph-definition.yaml
	manual_root=$platform_root/k8s/bases/apps/ascoachingogvaner
	manual_namespace=$manual_root/namespace.yaml
	manual_service_account=$manual_root/service-account.yaml
	manual_role_binding=$manual_root/role-binding-ascoachingogvaner.yaml
	manual_kustomization=$manual_root/flux-kustomization.yaml

	for required_file in \
		"$rgd" \
		"$manual_namespace" \
		"$manual_service_account" \
		"$manual_role_binding" \
		"$manual_kustomization"
	do
		[ -f "$required_file" ] || fail "Platform tenant-envelope source is missing: $required_file"
	done

	# shellcheck disable=SC2016
	yq eval -e '
		(.spec.resources[] | select(.id == "tenantNamespace").template) as $namespace
		| (.spec.resources[] | select(.id == "serviceAccount").template) as $serviceAccount
		| (.spec.resources[] | select(.id == "roleBinding").template) as $roleBinding
		| (.spec.resources[] | select(.id == "kustomization").template) as $kustomization
		| (.spec.resources[] | select(.id == "kustomizationSops").template) as $kustomizationSops
		| ($namespace.kind == "Namespace"
		and $namespace.metadata.name == "${schema.spec.name}"
		and $namespace.metadata.labels."app.kubernetes.io/managed-by" == "ksail"
		and $namespace.metadata.labels."pod-security.kubernetes.io/enforce" == "restricted"
		and $namespace.metadata.labels."pod-security.kubernetes.io/enforce-version" == "latest"
		and $serviceAccount.kind == "ServiceAccount"
		and $serviceAccount.metadata.name == "${schema.spec.name}"
		and $serviceAccount.metadata.namespace == "${tenantNamespace.metadata.name}"
		and $serviceAccount.metadata.labels."app.kubernetes.io/managed-by" == "ksail"
		and $serviceAccount.automountServiceAccountToken == false
		and $roleBinding.kind == "RoleBinding"
		and $roleBinding.metadata.name == "${schema.spec.name}"
		and $roleBinding.metadata.namespace == "${tenantNamespace.metadata.name}"
		and $roleBinding.roleRef.apiGroup == "rbac.authorization.k8s.io"
		and $roleBinding.roleRef.kind == "ClusterRole"
		and $roleBinding.roleRef.name == "tenant-edit"
		and ($roleBinding.subjects | length) == 1
		and $roleBinding.subjects[0].kind == "ServiceAccount"
		and $roleBinding.subjects[0].name == "${serviceAccount.metadata.name}"
		and $roleBinding.subjects[0].namespace == "${tenantNamespace.metadata.name}"
		and $kustomization.metadata.namespace == "${tenantNamespace.metadata.name}"
		and $kustomization.spec.serviceAccountName == "${serviceAccount.metadata.name}"
		and $kustomization.spec.targetNamespace == "${tenantNamespace.metadata.name}"
		and $kustomizationSops.metadata.namespace == "${tenantNamespace.metadata.name}"
		and $kustomizationSops.spec.serviceAccountName == "${serviceAccount.metadata.name}"
		and $kustomizationSops.spec.targetNamespace == "${tenantNamespace.metadata.name}")
	' "$rgd" >/dev/null || fail "Platform KRO Tenant no longer provides the required namespace, RBAC, and Flux envelope"

	tenant_name=$(yq eval -r '.metadata.name // ""' "$manual_namespace")
	[ -n "$tenant_name" ] || fail "manual Platform tenant namespace has no name"
	export tenant_name

	# shellcheck disable=SC2016
	yq eval -e '
		.metadata.name == strenv(tenant_name)
		and .metadata.labels."app.kubernetes.io/managed-by" == "ksail"
		and .metadata.labels."pod-security.kubernetes.io/enforce" == "restricted"
		and .metadata.labels."pod-security.kubernetes.io/enforce-version" == "latest"
	' "$manual_namespace" >/dev/null || fail "manual Platform tenant namespace lacks the managed restricted envelope"

	# shellcheck disable=SC2016
	yq eval -e '
		.kind == "ServiceAccount"
		and .metadata.name == strenv(tenant_name)
		and .metadata.namespace == strenv(tenant_name)
		and .metadata.labels."app.kubernetes.io/managed-by" == "ksail"
		and .automountServiceAccountToken == false
	' "$manual_service_account" >/dev/null || fail "manual Platform tenant ServiceAccount no longer matches its namespace"

	# shellcheck disable=SC2016
	yq eval -e '
		.kind == "RoleBinding"
		and .metadata.name == strenv(tenant_name)
		and .metadata.namespace == strenv(tenant_name)
		and .roleRef.apiGroup == "rbac.authorization.k8s.io"
		and .roleRef.kind == "ClusterRole"
		and .roleRef.name == "tenant-edit"
		and (.subjects | length) == 1
		and .subjects[0].kind == "ServiceAccount"
		and .subjects[0].name == strenv(tenant_name)
		and .subjects[0].namespace == strenv(tenant_name)
	' "$manual_role_binding" >/dev/null || fail "manual Platform tenant RoleBinding no longer grants tenant-edit to its reconciler"

	# shellcheck disable=SC2016
	yq eval -e '
		.kind == "Kustomization"
		and .metadata.name == strenv(tenant_name)
		and .metadata.namespace == strenv(tenant_name)
		and .metadata.labels."app.kubernetes.io/managed-by" == "ksail"
		and .spec.serviceAccountName == strenv(tenant_name)
		and .spec.targetNamespace == strenv(tenant_name)
	' "$manual_kustomization" >/dev/null || fail "manual Platform tenant Flux Kustomization no longer impersonates and targets its namespace"
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 2 ] || fail "usage: $0 --validate <platform-root>"
	validate_platform "$2"
	exit 0
fi

platform_root=${PLATFORM_ROOT:-$repo_root/.platform}
validate_platform "$platform_root"

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT
baseline=$mutation_dir/baseline
mkdir -p \
	"$baseline/k8s/bases/infrastructure/resource-graph-definitions" \
	"$baseline/k8s/bases/apps"
cp -R \
	"$platform_root/k8s/bases/infrastructure/resource-graph-definitions/tenant" \
	"$baseline/k8s/bases/infrastructure/resource-graph-definitions/tenant"
cp -R \
	"$platform_root/k8s/bases/apps/ascoachingogvaner" \
	"$baseline/k8s/bases/apps/ascoachingogvaner"

run_mutation() {
	description=$1
	relative_file=$2
	mutation=$3
	mutant=$mutation_dir/mutant
	rm -rf "$mutant"
	cp -R "$baseline" "$mutant"
	yq eval "$mutation" "$mutant/$relative_file" > "$mutation_dir/mutant.yaml"
	mv "$mutation_dir/mutant.yaml" "$mutant/$relative_file"
	if (validate_platform "$mutant") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

rgd_path=k8s/bases/infrastructure/resource-graph-definitions/tenant/resource-graph-definition.yaml
manual_path=k8s/bases/apps/ascoachingogvaner
run_mutation "KRO managed-by label removed" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "tenantNamespace").template.metadata.labels."app.kubernetes.io/managed-by")'
run_mutation "KRO Pod Security level weakened" "$rgd_path" \
	'(.spec.resources[] | select(.id == "tenantNamespace").template.metadata.labels."pod-security.kubernetes.io/enforce") = "baseline"'
run_mutation "KRO tenant-edit binding changed" "$rgd_path" \
	'(.spec.resources[] | select(.id == "roleBinding").template.roleRef.name) = "edit"'
run_mutation "KRO non-SOPS reconciler identity removed" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "kustomization").template.spec.serviceAccountName)'
run_mutation "KRO non-SOPS target namespace removed" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "kustomization").template.spec.targetNamespace)'
run_mutation "KRO SOPS reconciler identity removed" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "kustomizationSops").template.spec.serviceAccountName)'
run_mutation "KRO SOPS target namespace removed" "$rgd_path" \
	'del(.spec.resources[] | select(.id == "kustomizationSops").template.spec.targetNamespace)'
run_mutation "manual managed-by label changed" "$manual_path/namespace.yaml" \
	'.metadata.labels."app.kubernetes.io/managed-by" = "manual"'
run_mutation "manual Pod Security level weakened" "$manual_path/namespace.yaml" \
	'.metadata.labels."pod-security.kubernetes.io/enforce" = "baseline"'
run_mutation "manual tenant-edit binding changed" "$manual_path/role-binding-ascoachingogvaner.yaml" \
	'.roleRef.name = "edit"'
run_mutation "manual reconciler identity removed" "$manual_path/flux-kustomization.yaml" \
	'del(.spec.serviceAccountName)'
run_mutation "manual target namespace removed" "$manual_path/flux-kustomization.yaml" \
	'del(.spec.targetNamespace)'

echo "PASS: Platform tenant envelope (KRO + manual registration + 12 safety mutations)"
