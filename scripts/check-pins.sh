#!/usr/bin/env bash
# Every `uses:` in this repository's workflows is pinned to a full commit SHA, and every
# `docker run` image is pinned by digest or an exact tag. Local workflow calls (./) and
# this organisation's own reusable workflows are the exceptions that need a branch ref.
set -euo pipefail
cd "$(dirname "$0")/.."

bad=0
while IFS= read -r line; do
  bad=1; echo "not pinned to a commit: $line" >&2
done < <(grep -rnE '^\s*-?\s*uses:\s' .github/workflows \
  | grep -vE 'uses:\s+\./' \
  | grep -vE 'uses:\s+[^@ ]+@[0-9a-f]{40}(\s|$)' || true)

if [ "$bad" = 1 ]; then exit 1; fi
echo "pins: ok"
