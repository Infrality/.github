# Infrality/.github

Reusable GitHub Actions workflows for every Infrality repo (README.md explains them).

- Gate: `make check` before every commit (actionlint, shellcheck, pins, retention self-test, gitleaks).
- Every `uses:` of a third-party action is pinned to a full commit SHA with the version in a comment.
  Containers are pinned by digest. The only branch refs are our own reusable workflows (`@main`).
- `.github/workflows/image.yml` must not be renamed or moved: its path is in the cosign identity that
  platform's `deploy-service.sh` verifies.
- Never push, never commit to `main`; `feat/…`, `fix/…`, `chore/…` branches, conventional commits.
