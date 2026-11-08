# Infrality/.github

Reusable CI/CD workflows for every Infrality repository. This repository is **public** on purpose:
that is what lets the private repositories call it on the Free plan.

| Workflow | What it does | Called by |
| --- | --- | --- |
| `ci-node.yml` | install, typecheck, lint, build, `npm audit`, actionlint, hadolint, tests (optional throwaway PostgreSQL) | api, app, website, docs, admin |
| `ci-go.yml` | modules, vet, golangci-lint, govulncheck, race tests + coverage gate, goreleaser check | agent |
| `security.yml` | TruffleHog, gitleaks, Semgrep (pinned containers) | every repo, on PRs and weekly |
| `image.yml` | build → push by digest → Trivy (fails on HIGH/CRITICAL) → semver tag → SBOM (syft) → cosign keyless → verify | api, app, website, docs, admin |
| `release-please.yml` | release PR (CHANGELOG + version) and the `vX.Y.Z` tag | every repo |
| `deploy-prod.yml` | **manual button only**: verify, join the tailnet, `deploy.sh <service> <digest>` | api, app, website, docs, admin |
| `deploy-staging.yml` | same, to the homelab VM, then Playwright + k6. **Off**: see below | dispatch-only callers |
| `ghcr-retention.yml` | weekly: keep the 10 newest releases per image (+ signatures), delete the rest | itself (schedule) |

`default.json` is the shared Renovate preset (`"extends": ["github>Infrality/.github"]`).
`make check` is this repository's gate (actionlint, shellcheck, pins, retention self-test, gitleaks).

## The signing identity is a contract

`platform/scripts/deploy-service.sh` refuses any digest that was not signed by

```
https://github.com/Infrality/(.github|<repo>)/.github/workflows/image.yml@refs/(heads/main|tags/v.+)
```

Keyless cosign signs as the **called** workflow, so:

- `image.yml` must stay at `.github/workflows/image.yml` in this repository;
- callers must reference it as `Infrality/.github/.github/workflows/image.yml@main`, never a SHA or
  another branch (Renovate is told to leave it alone). The last step of `image.yml` runs the server's
  exact `cosign verify`, so a wrong ref fails the build, not the deploy;
- the cosign version is pinned to the one on the servers (`v3.1.4`).

## A caller, in full

```yaml
# <repo>/.github/workflows/release.yml
name: Release
on: { push: { branches: [main] } }
permissions: { contents: read }
jobs:
  release-please:
    permissions: { contents: write, pull-requests: write }
    uses: Infrality/.github/.github/workflows/release-please.yml@main
    secrets: { RELEASE_PLEASE_TOKEN: "${{ secrets.RELEASE_PLEASE_TOKEN }}" }
  image:
    needs: release-please
    if: needs.release-please.outputs.release_created == 'true'
    permissions: { contents: read, packages: write, id-token: write }
    uses: Infrality/.github/.github/workflows/image.yml@main
    with: { image: app, ref: "${{ needs.release-please.outputs.tag_name }}" }
```

The same pattern for CI (`ci-node.yml`), the pull-request image scan (`image.yml`, `push: false`), the
weekly scan (`security.yml`), and `deploy-prod.yml` / `deploy-staging.yml`.

## Release → production

1. Merge conventional commits to `main`. release-please opens/updates the release PR.
2. Merging the release PR tags `vX.Y.Z`; the same workflow run builds, scans, signs and pushes
   `ghcr.io/infrality/<repo>:X.Y.Z` (and `@sha256:…`).
3. **Actions → Deploy production → Run workflow**, `ref = vX.Y.Z`. Nothing else deploys to production.
   `deploy-prod.yml` refuses anything but a `workflow_dispatch` on `main` for a release tag that is in
   `main`'s history; resolves the digest; verifies the signature; joins the tailnet as `tag:ci`; runs
   `deploy.sh <service> <digest>` through the server's SSH gate, which rolls out with no downtime, smoke
   tests, and rolls back on failure.

Images are built once and promoted: nothing environment-specific is baked in. `app` and `website` read
`PUBLIC_*` at run time (`$env/dynamic/public`).

## One-time setup (not code: do these in the GitHub / Tailscale UIs)

Organisation (Free plan: no Environments, no branch protection, 2,000 Actions minutes, 500 MB GHCR):

- Settings → Actions → General: allow actions and reusable workflows from this organisation.
- Per repository: Settings → Actions → "Allow GitHub Actions to create and approve pull requests"
  (release-please).
- Packages: each image's *Manage Actions access* lets its repository publish (first push creates it).
- Install the Renovate GitHub App on the organisation; remove Dependabot.

| Where | Name | What |
| --- | --- | --- |
| org secret | `TS_AUTHKEY` | Tailscale auth key: **ephemeral**, reusable, pre-approved, tag `tag:ci` |
| org var | `SSH_HOST`, `SSH_USER` | the VPS's tailnet name, and the deploy user |
| org secret | `SSH_KNOWN_HOSTS` | the VPS host key line, from `ssh-keyscan` run from a trusted machine over the tailnet |
| repo secret | `SSH_DEPLOY_KEY_BACKEND` (api), `_FRONTEND` (app), `_WEBSITE`, `_DOCS`, `_ADMIN` | the existing per-service keys; their `authorized_keys` lines keep `command="infrality-ssh-gate <role>"` |
| repo secret | `RELEASE_PLEASE_TOKEN` | optional PAT; **required for agent** so release-please's tag starts goreleaser's `release.yml` |
| this repo secret | `GHCR_RETENTION_TOKEN` | PAT with `read:packages` + `delete:packages` (retention only) |

Tailscale ACL: `tag:ci` may reach `tag:prod` on port 22 and nothing else (platform `docs/OPERATIONS.md`).

## What is switched off

There is **no staging** for now: no homelab VM, runner or tunnel. `deploy-staging.yml` is prepared (digest
resolution, signature check, `deploy.sh` over the LAN, Playwright, k6) but only reachable through the
repositories' `deploy-staging.yml`, which are `workflow_dispatch`-only. Nothing runs it and nothing
fails for its absence. To switch it on: build the VM from platform's staging overlay, register a
self-hosted runner labelled `homelab`, add `STAGING_SSH_KEY` / `STAGING_KNOWN_HOSTS`. Heavy jobs take a
`runs-on` input for the day they move to that runner. Builds are `linux/amd64` only, with layer caching
(`type=gha`); end-to-end and k6 runs happen only when dispatched.

## Deviations from the brief, and why

- **CodeQL, dependency-review**: both need GitHub Advanced Security on a private repository. Semgrep
  (`p/default`, language packs, `p/secrets`) covers SAST; `npm audit` / `govulncheck` cover dependencies.
- **Trivy and the gitleaks CLI run as pinned containers**, not their actions (the Trivy action's tags
  were rewritten in March 2026; gitleaks-action needs a licence for organisations).
- **Retention keeps signatures.** "Delete untagged" alone would delete the per-platform manifests of a
  kept release and the cosign signatures `deploy.sh` demands; see `scripts/ghcr-retention.sh`.
