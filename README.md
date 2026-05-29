# gitops-tenant-template

A template for **GitOps tenants** on the
[devantler-tech platform](https://github.com/devantler-tech/platform) — an
application that runs on the platform from its own repository. The template ships
the shared, **framework-agnostic** CI/CD plumbing (build → signed publish →
release) and keeps it current in every tenant via
[template-sync](https://github.com/AndreasAugustin/actions-template-sync).

It is intentionally **stack-neutral**: it carries no application code or
language-specific tooling. Bring your own stack (any language, any framework) and
fill in the scaffolding.

## Use this template

1. Click **"Use this template" → Create a new repository** (or
   `gh repo create devantler-tech/<tenant> --template devantler-tech/gitops-tenant-template --private`).
2. Replace the scaffolding with your app: application code, `Dockerfile`, the
   `deploy/` manifests, the `ci.yaml` jobs, and fill in `AGENTS.md`.
3. Create `.templatesyncignore` (see below).
4. Register the tenant on the platform — follow
   [`platform/docs/TENANTS.md`](https://github.com/devantler-tech/platform/blob/main/docs/TENANTS.md).

## What the template owns vs. what you own

template-sync overwrites the files the template **owns** and never touches the
files **you own**. Declare the files you own in **`.templatesyncignore`** (same
syntax as `.gitignore`). template-sync only ever brings over files that exist in
this template, so you only need to ignore the scaffolding files below — not your
app code.

**Owned by the template (kept in sync — do not edit in your tenant):**

| File | Purpose |
|---|---|
| `.github/workflows/cd.yaml` | On a `v*` tag, calls `publish-app.yaml` to build, digest-pin, push, and **cosign-sign** the image + manifests OCI artifact |
| `.github/workflows/release.yaml` | semantic-release on `main` (cuts the `v*` tags that drive `cd.yaml`) |
| `.github/workflows/template-sync.yaml` | Opens the weekly template-sync PR |
| `CLAUDE.md` | `@AGENTS.md` shim |
| `zizmor.yml` | GitHub Actions pinning policy enforced by the security scan |

**Yours (list these in `.templatesyncignore`):**

```gitignore
# Files this tenant owns — template-sync must never overwrite them.
AGENTS.md
.claude/skills/maintain/SKILL.md
.github/workflows/ci.yaml
.github/dependabot.yml
.releaserc
.gitignore
Dockerfile
README.md
LICENSE
deploy/
.templatesyncignore
```

`AGENTS.md` and the `maintain` skill ship as scaffolding (a starting point for new
tenants) but are **yours** — they carry your project-specific overview, so they are
ignored from sync.

## How publishing works

`release.yaml` turns Conventional-Commit merges to `main` into `vX.Y.Z` tags.
Each tag triggers `cd.yaml`, which calls the platform's
[`publish-app.yaml`](https://github.com/devantler-tech/reusable-workflows/blob/main/.github/workflows/publish-app.yaml)
reusable workflow to build the image, **pin its digest into
`deploy/deployment.yaml`**, push the manifests as an OCI artifact, and
**cosign-sign** both. The platform's `OCIRepository` verifies that signature, so
only artifacts from this trusted workflow are reconciled.

> **Convention:** the Deployment's container `name` MUST equal the repository
> name — `publish-app` pins the built image digest into the container with that
> name (`app-name: ${{ github.event.repository.name }}` in `cd.yaml`).

## Validate locally

```sh
kubectl kustomize deploy/        # manifests build
actionlint .github/workflows/*   # workflows parse
```
