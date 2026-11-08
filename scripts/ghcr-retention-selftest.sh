#!/usr/bin/env bash
# Runs scripts/ghcr-retention.sh against a fixture: 12 releases (two of them old and
# multi-platform), their signatures, stray untagged versions, one too young to touch.
# Expects exactly: the 2 oldest releases and their signature, and the orphan untagged
# versions, to be deleted; nothing a kept release needs.

set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
d() { printf 'sha256:%064d' "$1"; }
t() { printf 'sha256-%064d' "$1"; }
old() { date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ; }

{
  # Releases 1..12 (digest n), signature index for each (digest 100+n, tag sha256-n)
  for n in $(seq 1 12); do
    printf '{"id":%d,"name":"%s","created_at":"%s","metadata":{"container":{"tags":["1.0.%d"]}}}\n' "$n" "$(d "$n")" "$(old $((40 - n)))" "$n"
    printf '{"id":%d,"name":"%s","created_at":"%s","metadata":{"container":{"tags":["%s.sig"]}}}\n' $((100 + n)) "$(d $((100 + n)))" "$(old $((40 - n)))" "$(t "$n")"
  done
  # Per-platform children of releases 2 (old, doomed) and 12 (kept): untagged.
  printf '{"id":201,"name":"%s","created_at":"%s","metadata":{"container":{"tags":[]}}}\n' "$(d 201)" "$(old 38)"
  printf '{"id":212,"name":"%s","created_at":"%s","metadata":{"container":{"tags":[]}}}\n' "$(d 212)" "$(old 28)"
  # An orphan untagged version, old: deleted. A young one (release in flight): kept.
  printf '{"id":300,"name":"%s","created_at":"%s","metadata":{"container":{"tags":[]}}}\n' "$(d 300)" "$(old 30)"
  printf '{"id":301,"name":"%s","created_at":"%s","metadata":{"container":{"tags":[]}}}\n' "$(d 301)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # A tag this script does not own.
  printf '{"id":400,"name":"%s","created_at":"%s","metadata":{"container":{"tags":["main"]}}}\n' "$(d 400)" "$(old 35)"
} | jq -s . > "$tmp/versions.json"

jq -n --arg r2 "$(d 2)" --arg c2 "$(d 201)" --arg r12 "$(d 12)" --arg c12 "$(d 212)" \
  '{($r2): [$c2], ($r12): [$c12]}' > "$tmp/children.json"

out="$(RETENTION_VERSIONS_FILE="$tmp/versions.json" RETENTION_CHILDREN_FILE="$tmp/children.json" \
  scripts/ghcr-retention.sh infrality demo --keep 10 --min-age-hours 24)"
echo "$out"

want_deleted=(1 2 101 102 201 300)
for id in "${want_deleted[@]}"; do
  grep -q "version ${id} " <<<"$out" || { echo "FAIL: version $id should be deleted" >&2; exit 1; }
done
got="$(grep -c '^would delete' <<<"$out")"
[ "$got" -eq "${#want_deleted[@]}" ] || { echo "FAIL: expected ${#want_deleted[@]} deletions, got $got" >&2; exit 1; }
for id in 3 12 103 112 212 301 400; do
  ! grep -q "version ${id} " <<<"$out" || { echo "FAIL: version $id must be kept" >&2; exit 1; }
done
echo "ghcr-retention self-test: ok"
