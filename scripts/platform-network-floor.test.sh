#!/usr/bin/env sh
# Verify that Platform's generated namespace network floor remains compatible
# with the required day-one paths in this template's CiliumNetworkPolicy.
set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

validate_network_floor() {
	platform_policy=$1
	scaffold_policy=$2

	[ -f "$platform_policy" ] ||
		fail "Platform add-default-deny policy is missing: $platform_policy"
	[ -f "$scaffold_policy" ] ||
		fail "tenant scaffold network policy is missing: $scaffold_policy"

	# The matchless deny entries activate Cilium's default-deny mode without
	# naming traffic to reject. Any future traffic matcher would take precedence
	# over the tenant allow policy, so reject that drift explicitly.
	# Keep independent assertions in an array. yq's boolean operator changes the
	# input context of its right-hand expression, which can hide missing fields.
	# shellcheck disable=SC2016
	yq eval -e '
		[
			.kind == "ClusterPolicy",
			.metadata.name == "add-default-deny",
			([.spec.rules[] | select(.name == "generate-default-deny")] | length) == 1,
			([.spec.rules[] | select(.name == "generate-allow-dns")] | length) == 1,
			([.spec.rules[] | select(.name == "generate-default-deny-networkpolicy")] | length) == 1
		] | all
	' "$platform_policy" >/dev/null ||
		fail "Platform generated network floor no longer has all three required rules"
	# shellcheck disable=SC2016
	yq eval -e '
		.spec.rules[] | select(.name == "generate-default-deny") | [
			(.match.any[0].resources.kinds | [(length == 1), contains(["Namespace"])] | all),
			(.exclude.any[0].resources.names | [(length == 3), contains(["kube-node-lease"]), contains(["kube-public"]), contains(["kube-system"])] | all),
			.generate.generateExisting == true,
			.generate.apiVersion == "cilium.io/v2",
			.generate.kind == "CiliumNetworkPolicy",
			.generate.name == "default-deny",
			.generate.synchronize == true,
			(.generate.data.spec.endpointSelector | keys | length) == 0,
			.generate.data.spec.enableDefaultDeny.ingress == true,
			.generate.data.spec.enableDefaultDeny.egress == true,
			(.generate.data.spec.ingressDeny | [(length == 1), (.[0] | keys | length) == 0] | all),
			(.generate.data.spec.egressDeny | [(length == 1), (.[0] | keys | length) == 0] | all),
			(.generate.data.spec | has("ingress") | not),
			(.generate.data.spec | has("egress") | not)
		] | all
	' "$platform_policy" >/dev/null ||
		fail "Platform generated Cilium default-deny gained a traffic matcher or lost its fail-closed shape"
	# shellcheck disable=SC2016
	yq eval -e '
		.spec.rules[] | select(.name == "generate-allow-dns") | [
			(.match.any[0].resources.kinds | [(length == 1), contains(["Namespace"])] | all),
			(.exclude.any[0].resources.names | [(length == 3), contains(["kube-node-lease"]), contains(["kube-public"]), contains(["kube-system"])] | all),
			.generate.generateExisting == true,
			.generate.apiVersion == "cilium.io/v2",
			.generate.kind == "CiliumNetworkPolicy",
			.generate.name == "allow-dns",
			.generate.synchronize == true,
			(.generate.data.spec.endpointSelector | keys | length) == 0,
			.generate.data.spec.egress[0].toEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "kube-system",
			.generate.data.spec.egress[0].toEndpoints[0].matchLabels."k8s-app" == "kube-dns",
			(.generate.data.spec.egress[0].toPorts[0].ports | [(length == 2), contains([{"port": "53", "protocol": "TCP"}]), contains([{"port": "53", "protocol": "UDP"}])] | all)
		] | all
	' "$platform_policy" >/dev/null ||
		fail "Platform generated DNS allowance no longer covers kube-dns over TCP and UDP"
	# shellcheck disable=SC2016
	yq eval -e '
		.spec.rules[] | select(.name == "generate-default-deny-networkpolicy") | [
			(.match.any[0].resources.kinds | [(length == 1), contains(["Namespace"])] | all),
			(.exclude.any[0].resources.names | [(length == 3), contains(["kube-node-lease"]), contains(["kube-public"]), contains(["kube-system"])] | all),
			.generate.generateExisting == true,
			.generate.apiVersion == "networking.k8s.io/v1",
			.generate.kind == "NetworkPolicy",
			.generate.name == "default-deny",
			.generate.synchronize == true,
			(.generate.data.spec.podSelector | keys | length) == 0,
			(.generate.data.spec.policyTypes | [(length == 2), contains(["Ingress"]), contains(["Egress"])] | all),
			(.generate.data.spec | has("ingress") | not),
			(.generate.data.spec | has("egress") | not)
		] | all
	' "$platform_policy" >/dev/null ||
		fail "Platform generated network floor no longer has the compatible default-deny, DNS, and standard-policy shape"

	# shellcheck disable=SC2016
	yq eval -e '
		[
			.kind == "CiliumNetworkPolicy",
			.metadata.name == "app",
			(.spec.endpointSelector | keys | length) == 0,
			([.spec.ingress[] | select(.fromEntities | contains(["ingress"]))] | length) == 1,
			(.spec.ingress[] | select(.fromEntities | contains(["ingress"])) | .toPorts[0].ports | [(length == 1), contains([{"port": "3000", "protocol": "TCP"}])] | all),
			([.spec.ingress[] | select(.fromEndpoints[0] | keys | length == 0)] | length) == 1,
			([.spec.ingress[] | select(.fromEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "cnpg-system")] | length) == 1,
			(.spec.ingress[] | select(.fromEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "cnpg-system") | .toPorts[0].ports | [(length == 2), contains([{"port": "5432", "protocol": "TCP"}]), contains([{"port": "8000", "protocol": "TCP"}])] | all),
			([.spec.egress[] | select(.toEndpoints[0] | keys | length == 0)] | length) == 1,
			([.spec.egress[] | select(.toEntities | contains(["kube-apiserver"]))] | length) == 1,
			([.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s-app" == "kube-dns")] | length) == 1,
			(.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s-app" == "kube-dns") | .toEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "kube-system"),
			(.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s-app" == "kube-dns") | .toPorts[0].ports | [(length == 2), contains([{"port": "53", "protocol": "TCP"}]), contains([{"port": "53", "protocol": "UDP"}])] | all)
		] | all
	' "$scaffold_policy" >/dev/null ||
		fail "tenant scaffold no longer re-opens Gateway, namespace, CNPG, Kubernetes API, and DNS traffic"
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 3 ] ||
		fail "usage: $0 --validate <platform-root> <scaffold-network-policy>"
	validate_network_floor \
		"$2/k8s/bases/infrastructure/cluster-policies/best-practices/add-default-deny.yaml" \
		"$3"
	exit 0
fi

platform_root=${PLATFORM_ROOT:-$repo_root/.platform}
platform_policy=$platform_root/k8s/bases/infrastructure/cluster-policies/best-practices/add-default-deny.yaml
scaffold_policy=$repo_root/deploy/networkpolicy.yaml
validate_network_floor "$platform_policy" "$scaffold_policy"

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT
platform_baseline=$mutation_dir/platform.yaml
scaffold_baseline=$mutation_dir/scaffold.yaml
cp "$platform_policy" "$platform_baseline"
cp "$scaffold_policy" "$scaffold_baseline"

run_platform_mutation() {
	description=$1
	mutation=$2
	yq eval "$mutation" "$platform_baseline" > "$mutation_dir/platform-mutant.yaml"
	if (validate_network_floor "$mutation_dir/platform-mutant.yaml" "$scaffold_baseline") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_scaffold_mutation() {
	description=$1
	mutation=$2
	yq eval "$mutation" "$scaffold_baseline" > "$mutation_dir/scaffold-mutant.yaml"
	if (validate_network_floor "$platform_baseline" "$mutation_dir/scaffold-mutant.yaml") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_platform_mutation "matched ingress deny introduced" \
	'(.spec.rules[] | select(.name == "generate-default-deny").generate.data.spec.ingressDeny[0].fromEntities) = ["all"]'
run_platform_mutation "default-deny generation removed" \
	'del(.spec.rules[] | select(.name == "generate-default-deny"))'
run_platform_mutation "generated DNS TCP allowance removed" \
	'del(.spec.rules[] | select(.name == "generate-allow-dns").generate.data.spec.egress[0].toPorts[0].ports[] | select(.protocol == "TCP"))'
run_platform_mutation "standard default-deny kind changed" \
	'(.spec.rules[] | select(.name == "generate-default-deny-networkpolicy").generate.kind) = "CiliumNetworkPolicy"'
run_scaffold_mutation "Gateway ingress allowance removed" \
	'(.spec.ingress[] | select(.fromEntities | contains(["ingress"])).fromEntities) = ["cluster"]'
run_scaffold_mutation "same-namespace ingress allowance removed" \
	'del(.spec.ingress[] | select(.fromEndpoints[0] | keys | length == 0))'
run_scaffold_mutation "Kubernetes API egress allowance removed" \
	'(.spec.egress[] | select(.toEntities | contains(["kube-apiserver"])).toEntities) = ["host"]'
run_scaffold_mutation "tenant DNS UDP allowance removed" \
	'del(.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s-app" == "kube-dns").toPorts[0].ports[] | select(.protocol == "UDP"))'

echo "PASS: Platform network floor (generated policies + tenant allows + 8 safety mutations)"
