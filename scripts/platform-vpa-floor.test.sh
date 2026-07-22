#!/usr/bin/env sh
# Verify that a fresh tenant starts at or above Platform's generated VPA CPU floor.
set -eu

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

millicores() {
	cpu_quantity=$1
	case "$cpu_quantity" in
		*m)
			cpu_number=${cpu_quantity%m}
			case "$cpu_number" in
				'' | *[!0-9]*) fail "CPU quantity must use positive canonical millicores: $cpu_quantity" ;;
			esac
		[ "$cpu_number" -gt 0 ] || fail "CPU quantity must be positive: $cpu_quantity"
		printf '%s\n' "$cpu_number"
		;;
	*) fail "CPU quantity must use canonical millicores: $cpu_quantity" ;;
	esac
}

validate_vpa_floor() {
	platform_root=$1
	scaffold_root=$2
	platform_policy=$platform_root/k8s/bases/infrastructure/cluster-policies/best-practices/auto-vpa.yaml
	deployment=$scaffold_root/deploy/deployment.yaml

	[ -f "$platform_policy" ] || fail "Platform auto-vpa policy is missing: $platform_policy"
	[ -f "$deployment" ] || fail "scaffold Deployment is missing: $deployment"

	platform_floors=$(yq eval -r '
		.spec.rules[]
		| select(.name == "generate-vpa-for-deployment")
		| select(
			(.match.resources.kinds | length) == 1
			and .match.resources.kinds[0] == "Deployment"
		)
		| select(.["generate"]["apiVersion"] == "autoscaling.k8s.io/v1")
		| select(.["generate"]["kind"] == "VerticalPodAutoscaler")
		| select(.["generate"]["data"]["spec"]["targetRef"]["apiVersion"] == "apps/v1")
		| select(.["generate"]["data"]["spec"]["targetRef"]["kind"] == "Deployment")
		| .["generate"]["data"]["spec"]["resourcePolicy"]["containerPolicies"][]
		| select(.["containerName"] == "*")
		| .["minAllowed"]["cpu"]
	' "$platform_policy")
	platform_floor_count=$(printf '%s\n' "$platform_floors" | awk 'NF { count++ } END { print count + 0 }')
	[ "$platform_floor_count" -eq 1 ] ||
		fail "expected exactly one Platform Deployment VPA CPU floor, found $platform_floor_count"
	platform_floor_m=$(millicores "$platform_floors")

	scaffold_requests=$(yq eval -r '
		select(.apiVersion == "apps/v1" and .kind == "Deployment")
		| .metadata.name as $workload_name
		| .spec.template.spec.containers[]
		| select(.name == $workload_name)
		| .resources.requests.cpu
	' "$deployment")
	scaffold_request_count=$(printf '%s\n' "$scaffold_requests" | awk 'NF { count++ } END { print count + 0 }')
	[ "$scaffold_request_count" -eq 1 ] ||
		fail "expected exactly one scaffold application CPU request, found $scaffold_request_count"
	scaffold_request_m=$(millicores "$scaffold_requests")

	[ "$scaffold_request_m" -ge "$platform_floor_m" ] ||
		fail "scaffold CPU request ${scaffold_requests} is below Platform VPA floor ${platform_floors}; raise deploy/deployment.yaml"

	printf 'Platform VPA floor contract: request=%s floor=%s\n' "$scaffold_requests" "$platform_floors"
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 3 ] || fail "usage: $0 --validate <platform-root> <scaffold-root>"
	validate_vpa_floor "$2" "$3"
	exit 0
fi

platform_root=${PLATFORM_ROOT:-$repo_root/.platform}
validate_vpa_floor "$platform_root" "$repo_root"
