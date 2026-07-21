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
	service=$3
	deployment=$4
	http_route=$5

	[ -f "$platform_policy" ] ||
		fail "Platform add-default-deny policy is missing: $platform_policy"
	[ -f "$scaffold_policy" ] ||
		fail "tenant scaffold network policy is missing: $scaffold_policy"
	[ -f "$service" ] || fail "rendered tenant Service is missing: $service"
	[ -f "$deployment" ] || fail "rendered tenant Deployment is missing: $deployment"
	[ -f "$http_route" ] || fail "rendered tenant HTTPRoute is missing: $http_route"

	# Cilium's IngressDenyRule/EgressDenyRule fields explicitly define an omitted
	# member as having no effect, so the matchless deny entries reject no traffic;
	# enableDefaultDeny activates isolation. Any future matcher would take
	# precedence over the tenant allow policy, so reject that drift explicitly.
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
			(has("preconditions") | not),
			(.match.any | length) == 1,
			(.match.any[0].resources | keys | length) == 1,
			(.match.any[0].resources.kinds | [(length == 1), contains(["Namespace"])] | all),
			(.exclude.any | length) == 1,
			(.exclude.any[0].resources | keys | length) == 1,
			(.exclude.any[0].resources.names | [(length == 3), contains(["kube-node-lease"]), contains(["kube-public"]), contains(["kube-system"])] | all),
			.generate.generateExisting == true,
			.generate.apiVersion == "cilium.io/v2",
			.generate.kind == "CiliumNetworkPolicy",
			.generate.name == "default-deny",
			.generate.namespace == "{{request.object.metadata.name}}",
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
			(has("preconditions") | not),
			(.match.any | length) == 1,
			(.match.any[0].resources | keys | length) == 1,
			(.match.any[0].resources.kinds | [(length == 1), contains(["Namespace"])] | all),
			(.exclude.any | length) == 1,
			(.exclude.any[0].resources | keys | length) == 1,
			(.exclude.any[0].resources.names | [(length == 3), contains(["kube-node-lease"]), contains(["kube-public"]), contains(["kube-system"])] | all),
			.generate.generateExisting == true,
			.generate.apiVersion == "cilium.io/v2",
			.generate.kind == "CiliumNetworkPolicy",
			.generate.name == "allow-dns",
			.generate.namespace == "{{request.object.metadata.name}}",
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
			(has("preconditions") | not),
			(.match.any | length) == 1,
			(.match.any[0].resources | keys | length) == 1,
			(.match.any[0].resources.kinds | [(length == 1), contains(["Namespace"])] | all),
			(.exclude.any | length) == 1,
			(.exclude.any[0].resources | keys | length) == 1,
			(.exclude.any[0].resources.names | [(length == 3), contains(["kube-node-lease"]), contains(["kube-public"]), contains(["kube-system"])] | all),
			.generate.generateExisting == true,
			.generate.apiVersion == "networking.k8s.io/v1",
			.generate.kind == "NetworkPolicy",
			.generate.name == "default-deny",
			.generate.namespace == "{{request.object.metadata.name}}",
			.generate.synchronize == true,
			(.generate.data.spec.podSelector | keys | length) == 0,
			(.generate.data.spec.policyTypes | [(length == 2), contains(["Ingress"]), contains(["Egress"])] | all),
			(.generate.data.spec | has("ingress") | not),
			(.generate.data.spec | has("egress") | not)
		] | all
	' "$platform_policy" >/dev/null ||
		fail "Platform generated network floor no longer has the compatible default-deny, DNS, and standard-policy shape"

	# Bind the Gateway allowance to the rendered route, Service, and Deployment
	# rather than a duplicated literal port. A valid Kustomize patch must not be
	# able to move the workload while leaving this contract green.
	# shellcheck disable=SC2016
	yq eval -e '
		[
			.kind == "Service",
			.metadata.name == "app",
			(.metadata | has("namespace") | not),
			(.spec.selector | keys | length) == 1,
			.spec.selector."app.kubernetes.io/name" == "app",
			([.spec.ports[] | select(.name == "http")] | length) == 1
		] | all
	' "$service" >/dev/null || fail "rendered tenant Service lacks one named HTTP port"
	# shellcheck disable=SC2016
	yq eval -e '
		[
			.kind == "Deployment",
			.metadata.name == "app",
			(.metadata | has("namespace") | not),
			.spec.template.metadata.labels."app.kubernetes.io/name" == "app",
			([.spec.template.spec.containers[] | select(.name == "app")] | length) == 1
		] | all
	' "$deployment" >/dev/null || fail "rendered tenant Deployment lacks the app container"
	# shellcheck disable=SC2016
	yq eval -e '
		[
			.kind == "HTTPRoute",
			.metadata.name == "app",
			(.metadata | has("namespace") | not),
			(.spec.parentRefs | length) == 1,
			.spec.parentRefs[0].name == "platform",
			.spec.parentRefs[0].namespace == "kube-system",
			.spec.parentRefs[0].sectionName == "https",
			([.spec.rules[].backendRefs[] | select(.name == "app")] | length) == 1
		] | all
	' "$http_route" >/dev/null || fail "rendered tenant HTTPRoute lacks one app backend"

	app_service_port=$(yq eval -r '.spec.ports[] | select(.name == "http") | .port | tostring' "$service")
	app_target_port=$(yq eval -r '.spec.ports[] | select(.name == "http") | .targetPort | tostring' "$service")
	case $app_service_port:$app_target_port in
		*null* | :* | *:) fail "rendered tenant Service has an incomplete HTTP port mapping" ;;
	esac
	export app_service_port app_target_port
	# shellcheck disable=SC2016
	yq eval -e '
		[.spec.template.spec.containers[]
			| select(.name == "app")
			| .ports[]
			| select((.containerPort | tostring) == strenv(app_target_port))
		] | length == 1
	' "$deployment" >/dev/null ||
		fail "rendered Service targetPort no longer matches the app container port"
	# shellcheck disable=SC2016
	yq eval -e '
		[.spec.rules[].backendRefs[]
			| select(.name == "app")
			| select((.port | tostring) == strenv(app_service_port))
		] | length == 1
	' "$http_route" >/dev/null ||
		fail "rendered HTTPRoute backend port no longer matches the app Service port"

	# shellcheck disable=SC2016
	yq eval -e '
		[
			.kind == "CiliumNetworkPolicy",
			.metadata.name == "app",
			(.metadata | has("namespace") | not),
			(.spec.endpointSelector | keys | length) == 0,
			(.spec | has("ingressDeny") | not),
			(.spec | has("egressDeny") | not),
			([.spec.ingress[] | select(.fromEntities | contains(["ingress"]))] | length) == 1,
			(.spec.ingress[] | select(.fromEntities | contains(["ingress"])) | .toPorts[0].ports | [(length == 1), contains([{"port": strenv(app_target_port), "protocol": "TCP"}])] | all),
			([.spec.ingress[] | select(.fromEndpoints[0] | keys | length == 0)] | length) == 1,
			(.spec.ingress[] | select(.fromEndpoints[0] | keys | length == 0) | keys | length) == 1,
			([.spec.ingress[] | select(.fromEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "cnpg-system")] | length) == 1,
			(.spec.ingress[] | select(.fromEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "cnpg-system") | .toPorts[0].ports | [(length == 2), contains([{"port": "5432", "protocol": "TCP"}]), contains([{"port": "8000", "protocol": "TCP"}])] | all),
			([.spec.egress[] | select(.toEndpoints[0] | keys | length == 0)] | length) == 1,
			(.spec.egress[] | select(.toEndpoints[0] | keys | length == 0) | keys | length) == 1,
			([.spec.egress[] | select(.toEntities | contains(["kube-apiserver"]))] | length) == 1,
			([.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s-app" == "kube-dns")] | length) == 1,
			(.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s-app" == "kube-dns") | .toEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "kube-system"),
			(.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s-app" == "kube-dns") | .toPorts[0].ports | [(length == 2), contains([{"port": "53", "protocol": "TCP"}]), contains([{"port": "53", "protocol": "UDP"}])] | all)
		] | all
	' "$scaffold_policy" >/dev/null ||
		fail "rendered tenant scaffold no longer re-opens Gateway, namespace, CNPG, Kubernetes API, and DNS traffic"
}

extract_rendered_resource() {
	rendered_bundle=$1
	resource_kind=$2
	resource_name=$3
	output_file=$4
	export resource_kind resource_name
	resource_count=$(yq eval-all '
		select([.kind == strenv(resource_kind), .metadata.name == strenv(resource_name)] | all)
		| .kind
	' "$rendered_bundle" | wc -l | tr -d ' ')
	[ "$resource_count" -eq 1 ] ||
		fail "rendered scaffold has $resource_count $resource_kind/$resource_name resources; expected 1"
	yq eval-all '
		select([.kind == strenv(resource_kind), .metadata.name == strenv(resource_name)] | all)
	' "$rendered_bundle" > "$output_file"
}

render_scaffold() {
	deploy_root=$1
	output_dir=$2
	mkdir -p "$output_dir"
	rendered_bundle=$output_dir/all.yaml
	kubectl kustomize "$deploy_root" > "$rendered_bundle"
	extract_rendered_resource "$rendered_bundle" CiliumNetworkPolicy app "$output_dir/network-policy.yaml"
	extract_rendered_resource "$rendered_bundle" Service app "$output_dir/service.yaml"
	extract_rendered_resource "$rendered_bundle" Deployment app "$output_dir/deployment.yaml"
	extract_rendered_resource "$rendered_bundle" HTTPRoute app "$output_dir/http-route.yaml"
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 6 ] ||
		fail "usage: $0 --validate <platform-root> <network-policy> <service> <deployment> <http-route>"
	validate_network_floor \
		"$2/k8s/bases/infrastructure/cluster-policies/best-practices/add-default-deny.yaml" \
		"$3" "$4" "$5" "$6"
	exit 0
fi

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT
rendered_root=$mutation_dir/rendered
render_scaffold "$repo_root/deploy" "$rendered_root"

platform_root=${PLATFORM_ROOT:-$repo_root/.platform}
platform_policy=$platform_root/k8s/bases/infrastructure/cluster-policies/best-practices/add-default-deny.yaml
scaffold_policy=$rendered_root/network-policy.yaml
service=$rendered_root/service.yaml
deployment=$rendered_root/deployment.yaml
http_route=$rendered_root/http-route.yaml
validate_network_floor "$platform_policy" "$scaffold_policy" "$service" "$deployment" "$http_route"

platform_baseline=$mutation_dir/platform.yaml
scaffold_baseline=$mutation_dir/scaffold.yaml
service_baseline=$mutation_dir/service.yaml
deployment_baseline=$mutation_dir/deployment.yaml
http_route_baseline=$mutation_dir/http-route.yaml
cp "$platform_policy" "$platform_baseline"
cp "$scaffold_policy" "$scaffold_baseline"
cp "$service" "$service_baseline"
cp "$deployment" "$deployment_baseline"
cp "$http_route" "$http_route_baseline"

run_platform_mutation() {
	description=$1
	mutation=$2
	yq eval "$mutation" "$platform_baseline" > "$mutation_dir/platform-mutant.yaml"
	if (validate_network_floor \
		"$mutation_dir/platform-mutant.yaml" \
		"$scaffold_baseline" \
		"$service_baseline" \
		"$deployment_baseline" \
		"$http_route_baseline") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_scaffold_mutation() {
	description=$1
	mutation=$2
	yq eval "$mutation" "$scaffold_baseline" > "$mutation_dir/scaffold-mutant.yaml"
	if (validate_network_floor \
		"$platform_baseline" \
		"$mutation_dir/scaffold-mutant.yaml" \
		"$service_baseline" \
		"$deployment_baseline" \
		"$http_route_baseline") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_service_mutation() {
	description=$1
	mutation=$2
	yq eval "$mutation" "$service_baseline" > "$mutation_dir/service-mutant.yaml"
	if (validate_network_floor \
		"$platform_baseline" \
		"$scaffold_baseline" \
		"$mutation_dir/service-mutant.yaml" \
		"$deployment_baseline" \
		"$http_route_baseline") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_http_route_mutation() {
	description=$1
	mutation=$2
	yq eval "$mutation" "$http_route_baseline" > "$mutation_dir/http-route-mutant.yaml"
	if (validate_network_floor \
		"$platform_baseline" \
		"$scaffold_baseline" \
		"$service_baseline" \
		"$deployment_baseline" \
		"$mutation_dir/http-route-mutant.yaml") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_rendered_scaffold_mutation() {
	description=$1
	mutation=$2
	mutant_deploy=$mutation_dir/deploy-mutant
	mutant_rendered=$mutation_dir/rendered-mutant
	cp -R "$repo_root/deploy" "$mutant_deploy"
	yq eval "$mutation" "$mutant_deploy/kustomization.yaml" > "$mutation_dir/kustomization-mutant.yaml"
	mv "$mutation_dir/kustomization-mutant.yaml" "$mutant_deploy/kustomization.yaml"
	render_scaffold "$mutant_deploy" "$mutant_rendered"
	if (validate_network_floor \
		"$platform_baseline" \
		"$mutant_rendered/network-policy.yaml" \
		"$mutant_rendered/service.yaml" \
		"$mutant_rendered/deployment.yaml" \
		"$mutant_rendered/http-route.yaml") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_platform_mutation "matched ingress deny introduced" \
	'(.spec.rules[] | select(.name == "generate-default-deny").generate.data.spec.ingressDeny[0].fromEntities) = ["all"]'
run_platform_mutation "default-deny generation removed" \
	'del(.spec.rules[] | select(.name == "generate-default-deny"))'
run_platform_mutation "tenant namespace target removed" \
	'del(.spec.rules[] | select(.name == "generate-default-deny").generate.namespace)'
run_platform_mutation "additional namespace exclusion introduced" \
	'.spec.rules[] |= select(.name == "generate-default-deny") * {"exclude": {"any": (.exclude.any + [{"resources": {"selector": {"matchLabels": {"platform.devantler.tech/tenant": "true"}}}}])}}'
run_platform_mutation "generation-suppressing precondition introduced" \
	'(.spec.rules[] | select(.name == "generate-default-deny").preconditions) = {"all": [{"key": "{{request.object.metadata.name}}", "operator": "Equals", "value": "never-match"}]}'
run_platform_mutation "generated DNS TCP allowance removed" \
	'del(.spec.rules[] | select(.name == "generate-allow-dns").generate.data.spec.egress[0].toPorts[0].ports[] | select(.protocol == "TCP"))'
run_platform_mutation "standard default-deny kind changed" \
	'(.spec.rules[] | select(.name == "generate-default-deny-networkpolicy").generate.kind) = "CiliumNetworkPolicy"'
run_scaffold_mutation "Gateway ingress allowance removed" \
	'(.spec.ingress[] | select(.fromEntities | contains(["ingress"])).fromEntities) = ["cluster"]'
run_scaffold_mutation "same-namespace ingress allowance removed" \
	'del(.spec.ingress[] | select(.fromEndpoints[0] | keys | length == 0))'
run_scaffold_mutation "same-namespace ingress restricted to one port" \
	'(.spec.ingress[] | select(.fromEndpoints[0] | keys | length == 0).toPorts) = [{"ports": [{"port": "3000", "protocol": "TCP"}]}]'
run_scaffold_mutation "Kubernetes API egress allowance removed" \
	'(.spec.egress[] | select(.toEntities | contains(["kube-apiserver"])).toEntities) = ["host"]'
run_scaffold_mutation "tenant DNS UDP allowance removed" \
	'del(.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s-app" == "kube-dns").toPorts[0].ports[] | select(.protocol == "UDP"))'
run_scaffold_mutation "tenant Gateway deny override introduced" \
	'.spec.ingressDeny = [{"fromEntities": ["ingress"]}]'
run_scaffold_mutation "network policy moved outside the workload namespace" \
	'.metadata.namespace = "other-namespace"'
run_service_mutation "Service target port diverged from workload and network policy" \
	'(.spec.ports[] | select(.name == "http").targetPort) = 3001'
run_service_mutation "Service selector diverged from workload labels" \
	'.spec.selector."app.kubernetes.io/name" = "other-app"'
run_http_route_mutation "HTTPRoute detached from the Platform Gateway" \
	'.spec.parentRefs[0].name = "other-gateway"'
run_rendered_scaffold_mutation "Kustomize patch removed rendered Gateway allowance" \
	'.patches = [{"target": {"kind": "CiliumNetworkPolicy", "name": "app"}, "patch": "- op: remove\n  path: /spec/ingress/0"}]'

echo "PASS: Platform network floor (generated policies + tenant allows + 18 safety mutations)"
