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

	# shellcheck disable=SC2016
	platform_floor_records=$(yq eval -r '
		.spec.rules[]
		| .name as $rule_name
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
		| [$rule_name, .["minAllowed"]["cpu"]]
		| @tsv
	' "$platform_policy")
	platform_floor_count=$(printf '%s\n' "$platform_floor_records" | awk 'NF { count++ } END { print count + 0 }')
	[ "$platform_floor_count" -eq 1 ] ||
		fail "expected exactly one Platform Deployment VPA CPU floor, found $platform_floor_count"
	platform_rule_name=$(printf '%s\n' "$platform_floor_records" | awk -F '\t' 'NR == 1 { print $1 }')
	[ "$platform_rule_name" = "generate-vpa-for-deployment" ] ||
		fail "Platform Deployment VPA floor must use the canonical generate-vpa-for-deployment rule"
	platform_floors=$(printf '%s\n' "$platform_floor_records" | awk -F '\t' 'NR == 1 { print $2 }')
	platform_floor_m=$(millicores "$platform_floors")

	# shellcheck disable=SC2016
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

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT

platform_policy_rel=k8s/bases/infrastructure/cluster-policies/best-practices/auto-vpa.yaml
mkdir -p "$mutation_dir/platform/$(dirname -- "$platform_policy_rel")" "$mutation_dir/scaffold/deploy"
cp "$platform_root/$platform_policy_rel" "$mutation_dir/platform/$platform_policy_rel"
cp "$repo_root/deploy/deployment.yaml" "$mutation_dir/scaffold/deploy/deployment.yaml"

run_mutation() {
	description=$1
	platform_mutation=$2
	scaffold_mutation=$3

	cp "$platform_root/$platform_policy_rel" "$mutation_dir/platform/$platform_policy_rel"
	cp "$repo_root/deploy/deployment.yaml" "$mutation_dir/scaffold/deploy/deployment.yaml"

	if [ -n "$platform_mutation" ]; then
		yq eval "$platform_mutation" "$mutation_dir/platform/$platform_policy_rel" > "$mutation_dir/platform-mutant.yaml"
		mv "$mutation_dir/platform-mutant.yaml" "$mutation_dir/platform/$platform_policy_rel"
	fi
	if [ -n "$scaffold_mutation" ]; then
		yq eval "$scaffold_mutation" "$mutation_dir/scaffold/deploy/deployment.yaml" > "$mutation_dir/scaffold-mutant.yaml"
		mv "$mutation_dir/scaffold-mutant.yaml" "$mutation_dir/scaffold/deploy/deployment.yaml"
	fi

	if (validate_vpa_floor "$mutation_dir/platform" "$mutation_dir/scaffold") >/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

run_mutation "scaffold request lowered below the Platform floor" '' \
	'.spec.template.spec.containers[0].resources.requests.cpu = "10m"'
run_mutation "Platform Deployment VPA rule removed" \
	'del(.spec.rules[] | select(.name == "generate-vpa-for-deployment"))' ''
run_mutation "Platform floor raised above the scaffold request" \
	'(.spec.rules[] | select(.name == "generate-vpa-for-deployment") | .["generate"].data.spec.resourcePolicy.containerPolicies[] | select(.containerName == "*") | .minAllowed.cpu) = "60m"' ''
run_mutation "Platform Deployment VPA rule duplicated" \
	'.spec.rules += [.spec.rules[] | select(.name == "generate-vpa-for-deployment")]' ''
run_mutation "Platform Deployment VPA rule duplicated under another name" \
	'.spec.rules += [(.spec.rules[] | select(.name == "generate-vpa-for-deployment") | .name = "duplicate-vpa-for-deployment")]' ''
run_mutation "Platform CPU floor removed" \
	'del(.spec.rules[] | select(.name == "generate-vpa-for-deployment") | .["generate"].data.spec.resourcePolicy.containerPolicies[] | select(.containerName == "*") | .minAllowed.cpu)' ''
run_mutation "Platform CPU floor changed to a noncanonical quantity" \
	'(.spec.rules[] | select(.name == "generate-vpa-for-deployment") | .["generate"].data.spec.resourcePolicy.containerPolicies[] | select(.containerName == "*") | .minAllowed.cpu) = "0.05"' ''
run_mutation "scaffold application container duplicated" '' \
	'.spec.template.spec.containers += [.spec.template.spec.containers[0]]'

echo "PASS: Platform VPA floor contract (happy path + 8 safety mutations)"
