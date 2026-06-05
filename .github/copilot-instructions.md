# GitHub Copilot review instructions — gitops-tenant-template

`devantler-tech/gitops-tenant-template` is a **tenant scaffold**: a minimal
Kustomize application that deploys to the devantler-tech platform Kubernetes
cluster as a **signed, OCI-packaged** app, reconciled by Flux. Instances created
from it are **private platform-tenant apps**. Enforce the rules below when
reviewing. They complement `AGENTS.md` (the canonical, cross-tool instructions) —
keep both in sync; if a PR changes a convention here, it updates `AGENTS.md` too.

## Scope & altitude
- This is a **tenant scaffold, not a product** — the bias is minimal and
  idiomatic. Flag PRs that add unrelated infrastructure or non-scaffold complexity.
- `deploy/` holds the Kustomize manifests (Deployment, Service, HTTPRoute, an
  optional CNPG `Cluster`, and — when secrets are needed — a namespaced
  `SecretStore` + `ExternalSecret`). Review manifests **statically**; never assume
  they are applied to a live cluster as part of review.

## Secrets — never plaintext
- This stack sources secrets from **OpenBao via External Secrets** (`SecretStore`
  + `ExternalSecret`), not committed Secret data. **Flag any plaintext secret,
  credential, token, or hardcoded password** in a manifest, value file, or
  workflow — there must be no unencrypted secret material in the repo.

## Template-owned plumbing
- `cd.yaml`, `release.yaml`, `template-sync.yaml`, `CLAUDE.md`, and `zizmor.yml`
  come from the template and are kept in sync by template-sync. **Changes to them
  belong upstream in the template, not in an instance** — flag edits to these files
  that would be reverted by the next sync. Instance-tailored files must stay listed
  in `.templatesyncignore`.

## Kustomize & Flux
- Manifests must `kubectl kustomize deploy/` cleanly. Keep resources namespaced and
  consistent with the platform's conventions (HTTPRoute via Gateway API, CNPG for
  PostgreSQL). Flag malformed Kustomize (missing `kustomization.yaml` entries,
  dangling references).

## Commits, CI & security
- **PR titles must be Conventional Commits** (`feat:`/`fix:`/`chore:`/`docs:`/
  `ci:`/`refactor:`/`test:`) — semantic-release squash-merges the title into the
  release, so a non-conventional or bracket-prefixed title corrupts it. Flag
  violations.
- Workflow changes must pass `actionlint`. Pin third-party actions to a
  full-length commit SHA, set least-privilege `permissions:`, and keep the house
  workflows intact (`ci.yaml` is the PR gate; `cd.yaml` publishes the signed OCI
  artifact on `v*` tags). Flag unpinned actions and over-broad token scopes.
- Never weaken or skip a check to make CI pass (no disabled steps, `--no-verify`,
  or "flaky"-dismissals) — fix the underlying cause.
- This is a **private** tenant — never expose its contents publicly.

Keep this file concise (≤ 4000 chars — Copilot review truncates beyond that) and
in sync with `AGENTS.md`.
