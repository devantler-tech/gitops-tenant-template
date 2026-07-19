#!/usr/bin/env sh
# Validate the agent-maintenance contract copied into every new tenant.
#
# AGENTS.md and the maintain skill become tenant-owned immediately after a repo
# is created, so template sync cannot repair an unsafe bootstrap later. This
# test pins the safety boundaries and exercises representative bypasses.
set -eu

# Resolve the scaffold that owns this test rather than the caller's checkout.
# New tenants may invoke scaffold helpers by path from another repository, and
# a cwd-derived Git root would validate the wrong AGENTS.md.
script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

require_literal() {
	description=$1
	needle=$2
	file=$3
	# Markdown line wrapping is presentation-only; validate the prose after
	# normalising newlines so reflowing a paragraph cannot weaken this guard.
	if ! tr '\n' ' ' < "$file" | grep -Fq -- "$needle"; then
		fail "$description"
	fi
}

forbid_literal() {
	description=$1
	needle=$2
	file=$3
	if tr '\n' ' ' < "$file" | grep -Fiq -- "$needle"; then
		fail "$description"
	fi
}

forbid_pattern() {
	description=$1
	pattern=$2
	file=$3
	if tr '\n' ' ' < "$file" | grep -Eiq -- "$pattern"; then
		fail "$description"
	fi
}

validate_contract() {
	agent_contract_file=$1
	skill_contract_file=$2

	require_literal "dependency automation must remain no-action" \
		"AUTOMATION-OWNED (NO-ACTION)" "$agent_contract_file"
	require_literal "ownership must be verified independently of branch shape" \
		"Branch names, authors, and disclosure text do not establish ownership" \
		"$agent_contract_file"
	require_literal "external contributions must stay static-review-only" \
		"static-review-only" "$agent_contract_file"
	require_literal "external code must never be checked out or executed" \
		"never check out or execute their code" "$agent_contract_file"
	require_literal "self-promotion must remain readiness-gated" \
		"Self-promote only when" "$agent_contract_file"
	require_literal "the complete hygiene pentad must remain required" \
		"complete hygiene pentad" "$agent_contract_file"
	require_literal "threads and review-body findings must remain clear" \
		"zero unresolved threads and current review-body findings" \
		"$agent_contract_file"
	require_literal "conflicts and base lag must remain clear" \
		"no conflict or base lag" "$agent_contract_file"
	require_literal "the supported pre-merge gate must remain required" \
		"supported CodeRabbit pre-merge check" "$agent_contract_file"
	require_literal "promotion must bind the exact current head" \
		"exact current head" "$agent_contract_file"
	require_literal "promotion must require a real user-path evaluation" \
		"tried and evaluated through a real user path" "$agent_contract_file"
	require_literal "own PRs must use a bare squash merge" \
		"gh pr merge <number> --squash" "$agent_contract_file"
	require_literal "only CLEAN own PRs may merge" \
		"merge only a CLEAN" "$agent_contract_file"
	require_literal "agents must never arm auto-merge" \
		"Never use \`--auto\`" "$agent_contract_file"
	require_literal "the maintain skill must defer to AGENTS.md" \
		"AGENTS.md" "$skill_contract_file"

	for contract_file in "$agent_contract_file" "$skill_contract_file"; do
		forbid_literal "retired maintainer-promotion gate returned" \
			"maintainer promotion" "$contract_file"
		forbid_literal "branch/actor trust list returned" \
			"trust gate =" "$contract_file"
		forbid_pattern "dependency bot or branch shape returned as trust" \
			'trust gate[[:space:]]*[:=].*(dependabot|renovate|claude/)' \
			"$contract_file"
		forbid_literal "retired vague self-merge rule returned" \
			"self-merge your own unreviewed drafts" "$contract_file"
	done
}

run_mutation() {
	description=$1
	mutation=$2

	cp "$repo_root/AGENTS.md" "$mutation_dir/AGENTS.md"
	cp "$repo_root/.claude/skills/maintain/SKILL.md" "$mutation_dir/SKILL.md"

	case "$mutation" in
	remove-bot-boundary)
		sed 's/AUTOMATION-OWNED (NO-ACTION)/dependency update/' \
			"$mutation_dir/AGENTS.md" > "$mutation_dir/AGENTS.tmp"
		mv "$mutation_dir/AGENTS.tmp" "$mutation_dir/AGENTS.md"
		;;
	restore-human-gate)
		sed 's/Self-promote/wait for maintainer promotion/' \
			"$mutation_dir/AGENTS.md" > "$mutation_dir/AGENTS.tmp"
		mv "$mutation_dir/AGENTS.tmp" "$mutation_dir/AGENTS.md"
		;;
	trust-branch-shape)
		printf "\ntrust gate = \`devantler\`, \`dependabot[bot]\`, \`claude/*\`\n" \
			>> "$mutation_dir/AGENTS.md"
		;;
	remove-exact-head)
		sed 's/\*\*exact$/\*\*branch/' \
			"$mutation_dir/AGENTS.md" > "$mutation_dir/AGENTS.tmp"
		mv "$mutation_dir/AGENTS.tmp" "$mutation_dir/AGENTS.md"
		;;
	remove-user-path)
		sed 's/must also be tried/must only be reviewed/' \
			"$mutation_dir/AGENTS.md" > "$mutation_dir/AGENTS.tmp"
		mv "$mutation_dir/AGENTS.tmp" "$mutation_dir/AGENTS.md"
		;;
	*) fail "unknown mutation: $mutation" ;;
	esac

	if (validate_contract "$mutation_dir/AGENTS.md" "$mutation_dir/SKILL.md") \
		>/dev/null 2>&1; then
		fail "mutation passed: $description"
	fi
}

if [ "${1:-}" = "--validate" ]; then
	[ "$#" -eq 3 ] || fail "usage: $0 --validate <AGENTS.md> <SKILL.md>"
	validate_contract "$2" "$3"
	exit 0
fi

validate_contract \
	"$repo_root/AGENTS.md" \
	"$repo_root/.claude/skills/maintain/SKILL.md"

mutation_dir=$(mktemp -d)
trap 'rm -rf "$mutation_dir"' EXIT

run_mutation "dependency-bot no-action removed" remove-bot-boundary
run_mutation "retired human-promotion gate restored" restore-human-gate
run_mutation "branch and actor shape treated as trust" trust-branch-shape
run_mutation "exact-head readiness removed" remove-exact-head
run_mutation "user-path evaluation removed" remove-user-path

echo "PASS: scaffolded agent contract (happy path + 5 safety mutations)"
