#!/usr/bin/env sh
# Exercise the rendered scaffold against Kubernetes Pod Security Admission.
set -eu

: "${KIND_NODE_IMAGE:?KIND_NODE_IMAGE must pin the Kind node image by digest}"
: "${POD_SECURITY_VERSION:?POD_SECURITY_VERSION must pin the restricted policy version}"

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
cluster_name="tenant-psa-${GITHUB_RUN_ID:-local}-$$"
namespace=tenant-pod-security-test
work_dir=$(mktemp -d)

cleanup() {
	kind delete cluster --name "$cluster_name" >/dev/null 2>&1 || true
	rm -rf "$work_dir"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

kind create cluster \
	--name "$cluster_name" \
	--image "$KIND_NODE_IMAGE" \
	--wait 120s

kubectl create namespace "$namespace"
kubectl label namespace "$namespace" \
	pod-security.kubernetes.io/enforce=restricted \
	"pod-security.kubernetes.io/enforce-version=$POD_SECURITY_VERSION"

kubectl kustomize "$repo_root/deploy" > "$work_dir/rendered.yaml"
NAMESPACE="$namespace" yq eval-all '
	select(.kind == "Deployment")
	| .apiVersion = "v1"
	| .kind = "Pod"
	| .metadata = {
		"name": .metadata.name,
		"namespace": strenv(NAMESPACE),
		"labels": .spec.template.metadata.labels
	  }
	| .spec = .spec.template.spec
' "$work_dir/rendered.yaml" > "$work_dir/deployment-pod.yaml"

kubectl apply --server-side --dry-run=server \
	--field-manager=tenant-scaffold-test \
	-f "$work_dir/deployment-pod.yaml" >/dev/null
echo "PASS: valid-scaffold admitted at restricted:$POD_SECURITY_VERSION"

expect_denied() {
	case_name=$1
	mutation=$2
	mutant="$work_dir/$case_name.yaml"
	output="$work_dir/$case_name.out"

	yq eval "$mutation" "$work_dir/deployment-pod.yaml" > "$mutant"
	if kubectl apply --server-side --dry-run=server \
		--field-manager=tenant-scaffold-test \
		-f "$mutant" >"$output" 2>&1; then
		cat "$output"
		fail "$case_name mutation was admitted"
	fi
	if ! grep -Fq "violates PodSecurity \"restricted:$POD_SECURITY_VERSION\"" "$output"; then
		cat "$output"
		fail "$case_name failed outside Pod Security Admission"
	fi
	echo "PASS: $case_name denied by restricted:$POD_SECURITY_VERSION"
}

expect_denied run-as-root \
	'.spec.containers[0].securityContext.runAsNonRoot = false'
expect_denied privilege-escalation \
	'.spec.containers[0].securityContext.allowPrivilegeEscalation = true'
expect_denied capability-add \
	'.spec.containers[0].securityContext.capabilities.add = ["SYS_ADMIN"]'

echo "PASS: Pod Security restricted admission (valid scaffold + 3 negative controls)"
