#!/usr/bin/env sh
# rename-placeholders.sh — turn this scaffold into a real tenant in one shot.
#
# The deploy/ manifests ship with two placeholders that both collapse to a single
# value — your tenant (repository) name:
#   • `app`       — the example app/resource name (Deployment, Service, the
#                   `app.kubernetes.io/name` label *value*, HTTPRoute, the CNPG
#                   Cluster, its database/owner, and the example hostname).
#   • REPLACE_ME  — values that MUST equal your repo name: the container image,
#                   the tenant's Vault role + ServiceAccount, and the OpenBao path.
# (Per the template convention the Deployment container `name` MUST equal the
# repository name — see README — so a single name drives everything.)
#
# Doing this by hand is easy to get half-wrong; this script renames both across
# deploy/*.yaml in place WITHOUT corrupting the parts that must NOT change:
#   • the `app.kubernetes.io/name` label *key* (only its value is renamed),
#   • CloudNativePG's literal `-app` suffix on its generated secret, and
#   • the shared `openbao` SecretStore name.
#
# Usage:  scripts/rename-placeholders.sh [tenant-name]
# With no argument it defaults to the repository directory name.
set -eu

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
name="${1:-$(basename "$repo_root")}"

# k8s resource names and the container name must be a DNS-1123 label.
if ! printf '%s' "$name" | grep -Eq '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'; then
  echo "error: '$name' is not a valid DNS-1123 label" >&2
  echo "       (lower-case alphanumerics and '-'; must start and end alphanumeric)." >&2
  echo "       pass an explicit name, e.g.: scripts/rename-placeholders.sh my-tenant" >&2
  exit 1
fi

deploy_dir="$repo_root/deploy"
[ -d "$deploy_dir" ] || {
  echo "error: $deploy_dir not found — run this from the tenant repository root." >&2
  exit 1
}

changed=0
for f in "$deploy_dir"/*.yaml; do
  [ -f "$f" ] || continue
  tmp="$f.rename.$$"
  # Order matters: the longer CNPG-secret suffix is handled before `app-db`, and
  # every `app*` rule is anchored to a YAML *value* position (": …$" / list item)
  # so neither the label key nor prose/comments are touched.
  sed \
    -e "s/REPLACE_ME/$name/g" \
    -e "s/: app-db-app\$/: $name-db-app/" \
    -e "s/: app-db\$/: $name-db/" \
    -e "s/: app-secrets\$/: $name-secrets/" \
    -e "s/app\\.platform\\.lan/$name.platform.lan/" \
    -e "s/: app\$/: $name/" \
    "$f" > "$tmp"
  if cmp -s "$f" "$tmp"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$f"
    changed=$((changed + 1))
  fi
done

echo "Renamed placeholders to '$name' across $changed file(s) in deploy/."
echo "Next: review with 'git diff', then 'kubectl kustomize deploy/' to confirm it builds."
