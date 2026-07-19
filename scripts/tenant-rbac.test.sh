#!/usr/bin/env sh
# Exercise the rendered scaffold through Platform's real tenant reconciliation RBAC.
set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
platform_roles_dir=${PLATFORM_CLUSTER_ROLES_DIR:-$repo_root/.platform/k8s/bases/infrastructure/cluster-roles}
namespace=tenant-rbac-test
service_account=tenant-reconciler
identity=system:serviceaccount:tenant-rbac-test:tenant-reconciler
work_dir=$(mktemp -d)

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[ -d "$platform_roles_dir" ] ||
	fail "Platform cluster-role checkout is missing: $platform_roles_dir"

for role_file in \
	tenant-edit.yaml \
	tenant-base-edit.yaml \
	cilium-tenant-edit.yaml \
	cnpg-tenant-edit.yaml \
	external-secrets-tenant-edit.yaml \
	gateway-tenant-edit.yaml
do
	[ -f "$platform_roles_dir/$role_file" ] ||
		fail "Platform tenant role is missing: $role_file"
	kubectl apply -f "$platform_roles_dir/$role_file" >/dev/null
done

kubectl create namespace "$namespace" >/dev/null
kubectl create serviceaccount "$service_account" --namespace "$namespace" >/dev/null
kubectl create rolebinding tenant-reconciler \
	--namespace "$namespace" \
	--clusterrole tenant-edit \
	--serviceaccount "$namespace:$service_account" >/dev/null

# The controller fills tenant-edit asynchronously from the labelled fragments.
# Wait on a real permission instead of sleeping and trusting timing.
attempt=0
while [ "$attempt" -lt 30 ]; do
	result=$(kubectl auth can-i get deployments.apps \
		--namespace "$namespace" --as="$identity" 2>/dev/null || true)
	[ "$result" = "yes" ] && break
	attempt=$((attempt + 1))
	sleep 1
done
[ "${result:-}" = "yes" ] ||
	fail "tenant-edit aggregation did not grant deployments.apps"

kubectl kustomize "$repo_root/deploy" > "$work_dir/rendered.yaml"
actual_inventory=$(yq eval-all -o=json -I=0 '[.]' "$work_dir/rendered.yaml" |
	jq -r '.[] | [.apiVersion, .kind] | @tsv' | sort)
expected_inventory=$(cat <<'INVENTORY'
apps/v1	Deployment
cilium.io/v2	CiliumNetworkPolicy
external-secrets.io/v1	ExternalSecret
external-secrets.io/v1	SecretStore
gateway.networking.k8s.io/v1	HTTPRoute
policy/v1	PodDisruptionBudget
postgresql.cnpg.io/v1	Cluster
v1	Service
INVENTORY
)

if [ "$actual_inventory" != "$expected_inventory" ]; then
	echo "--- actual rendered inventory ---" >&2
	printf '%s\n' "$actual_inventory" >&2
	echo "--- expected rendered inventory ---" >&2
	printf '%s\n' "$expected_inventory" >&2
	fail "rendered GVK inventory changed without an authorization mapping"
fi

subject_access_allowed() {
	sar_verb=$1
	sar_qualified_resource=$2
	sar_namespace=$3
	case "$sar_qualified_resource" in
		*.*)
			sar_resource=${sar_qualified_resource%%.*}
			sar_api_group=${sar_qualified_resource#*.}
			;;
		*)
			sar_resource=$sar_qualified_resource
			sar_api_group=
			;;
	esac

	sar_result=$(jq -n \
		--arg user "$identity" \
		--arg verb "$sar_verb" \
		--arg group "$sar_api_group" \
		--arg resource "$sar_resource" \
		--arg namespace "$sar_namespace" '
		{
		  apiVersion: "authorization.k8s.io/v1",
		  kind: "SubjectAccessReview",
		  spec: {
		    user: $user,
		    resourceAttributes: ({verb: $verb, resource: $resource}
		      + (if $group == "" then {} else {group: $group} end)
		      + (if $namespace == "" then {} else {namespace: $namespace} end))
		  }
		}
		' | kubectl create -f - -o json | jq -r '.status.allowed')
	[ "$sar_result" = "true" ]
}

expect_allowed() {
	allowed_verb=$1
	allowed_resource=$2
	if ! subject_access_allowed "$allowed_verb" "$allowed_resource" "$namespace"; then
		fail "$identity cannot $allowed_verb $allowed_resource"
	fi
}

for scaffold_resource in \
	deployments.apps \
	services \
	poddisruptionbudgets.policy \
	ciliumnetworkpolicies.cilium.io \
	externalsecrets.external-secrets.io \
	secretstores.external-secrets.io \
	httproutes.gateway.networking.k8s.io \
	clusters.postgresql.cnpg.io
do
	for scaffold_verb in get list watch create patch update delete; do
		expect_allowed "$scaffold_verb" "$scaffold_resource"
	done
done

expect_denied() {
	denied_verb=$1
	denied_resource=$2
	denied_namespace=${3:-}
	if subject_access_allowed "$denied_verb" "$denied_resource" "$denied_namespace"; then
		fail "$identity can unexpectedly $denied_verb $denied_resource"
	fi
	echo "PASS: $denied_verb $denied_resource denied"
}

expect_denied create clustersecretstores.external-secrets.io
expect_denied create ciliumclusterwidenetworkpolicies.cilium.io
expect_denied create namespaces
expect_denied create clusterroles.rbac.authorization.k8s.io
expect_denied create pods/exec "$namespace"

echo "PASS: Platform tenant RBAC (8 scaffold resources allowed, 5 boundaries denied)"
