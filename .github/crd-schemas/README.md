# Bundled CRD JSON schemas

These are the JSON schemas the `🧱 Validate Scaffold` CI workflow
(`.github/workflows/validate-scaffold.yaml`) uses to schema-validate the
CRD-backed resources rendered from `deploy/`. They are bundled **in-repo** so the
gate is deterministic and **network-free**: it no longer fetches schemas from the
datreeio CRDs-catalog over the network at CI time, so a transient
`raw.githubusercontent.com` outage can't make validation flake — and, because the
workflow runs without `-ignore-missing-schemas`, a CRD whose schema is missing
**fails the gate loudly** instead of being silently skipped.

The standard Kubernetes kinds (Service, Deployment, …) validate against
kubeconform's built-in default schemas and are not bundled here.

## What's bundled

One schema per CRD-backed resource the scaffold's `deploy/` manifests render:

| File | CRD | API version |
|---|---|---|
| `external-secrets.io/externalsecret_v1.json` | `ExternalSecret` | `external-secrets.io/v1` |
| `external-secrets.io/secretstore_v1.json` | `SecretStore` | `external-secrets.io/v1` |
| `gateway.networking.k8s.io/httproute_v1.json` | `HTTPRoute` | `gateway.networking.k8s.io/v1` |
| `postgresql.cnpg.io/cluster_v1.json` | `Cluster` (CloudNativePG) | `postgresql.cnpg.io/v1` |

The layout mirrors kubeconform's templated schema path
`{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json` (lowercased kind), so
the workflow points one `-schema-location` at this directory.

## Source & refresh

Sourced verbatim from the [datreeio CRDs-catalog](https://github.com/datreeio/CRDs-catalog),
pinned to commit `1f22207301c45da9ee687f6bbf728da049e6c105`.

To refresh (e.g. to pick up a new CRD field or a new API version), re-fetch from a
chosen catalog commit — bumping the schemas is then an intentional, reviewed change:

```sh
REF=<datreeio/CRDs-catalog commit>
BASE="https://raw.githubusercontent.com/datreeio/CRDs-catalog/${REF}"
curl -fsSL -o external-secrets.io/externalsecret_v1.json "$BASE/external-secrets.io/externalsecret_v1.json"
curl -fsSL -o external-secrets.io/secretstore_v1.json     "$BASE/external-secrets.io/secretstore_v1.json"
curl -fsSL -o gateway.networking.k8s.io/httproute_v1.json "$BASE/gateway.networking.k8s.io/httproute_v1.json"
curl -fsSL -o postgresql.cnpg.io/cluster_v1.json          "$BASE/postgresql.cnpg.io/cluster_v1.json"
```

**Adding a CRD to `deploy/`?** Bundle its schema here too (same layout). The gate
runs without `-ignore-missing-schemas`, so an unbundled CRD fails CI rather than
slipping through unvalidated.
