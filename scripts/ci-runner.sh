#!/usr/bin/env bash
# Switch where the private repositories' Linux jobs run, in one command:
#
#   scripts/ci-runner.sh self-hosted        # CI_RUNNER=infrality-ci in every private repo
#   scripts/ci-runner.sh hosted             # CI_RUNNER=ubuntu-latest (GitHub-hosted)
#   scripts/ci-runner.sh status             # print each repo's current value
#   scripts/ci-runner.sh hosted app api     # only these repos
#
# On GitHub Free, organisation variables are invisible to private repositories, so the switch
# is a repository variable, set in each one. The callers read it as
# `${{ vars.CI_RUNNER || 'ubuntu-latest' }}`; the reusable workflows refuse a self-hosted
# label for a public repository whatever the variable says. Windows and macOS jobs never use it.
# Needs `gh` logged in with Variables write on the repositories (a person, or the
# RUNNER_SWITCH_TOKEN of the "Switch CI runner" workflow). docs/CI-RUNNER.md explains the rest.
set -euo pipefail

ORG="${ORG:-Infrality}"
SELF_HOSTED_LABEL="${SELF_HOSTED_LABEL:-infrality-ci}"

mode="${1:-}"; shift || true
case "$mode" in
  self-hosted) value="$SELF_HOSTED_LABEL" ;;
  hosted) value=ubuntu-latest ;;
  status) value="" ;;
  *) echo "usage: $0 self-hosted|hosted|status [repo...]" >&2; exit 2 ;;
esac

if [ "$#" -gt 0 ]; then
  repos=("$@")
else
  repos=()  # a read loop, not mapfile: macOS still ships bash 3.2
  while IFS= read -r r; do repos+=("$r"); done < <(gh repo list "$ORG" --visibility private \
    --no-archived --limit 200 --json name --jq '.[].name' | sort)
fi
[ "${#repos[@]}" -gt 0 ] || { echo "no private repository found in $ORG" >&2; exit 1; }

fail=0
for repo in "${repos[@]}"; do
  if [ "$mode" = status ]; then
    current="$(gh variable get CI_RUNNER -R "$ORG/$repo" 2>/dev/null || echo '(unset: hosted)')"
    printf '%-12s %s\n' "$repo" "$current"
  elif gh variable set CI_RUNNER -R "$ORG/$repo" --body "$value" > /dev/null; then
    printf '%-12s CI_RUNNER=%s\n' "$repo" "$value"
  else
    printf '%-12s FAILED\n' "$repo" >&2; fail=1
  fi
done
exit "$fail"
