#!/usr/bin/env bash
# Keep the newest N release (or main-<sha7>) versions of one GHCR image, and everything they need;
# delete the rest.
#
#   scripts/ghcr-retention.sh <owner> <package> [--keep 10] [--min-age-hours 24] [--apply]
#
# Dry run unless --apply. Needs GH_TOKEN with read:packages + delete:packages (the
# Actions GITHUB_TOKEN of this repository cannot delete another repository's package),
# and, for the digests of multi-platform images, a logged-in `docker buildx`.
#
# A GHCR "version" is a manifest, not a tag, so "delete the untagged ones" on its own
# would break what it is meant to keep:
#   - a multi-platform release tag points at an index whose per-platform manifests are
#     UNTAGGED versions;
#   - cosign stores the signature and the SBOM attestation of a digest as artifacts
#     reachable from a tag `sha256-<hex>[.sig|.att]` (an index, whose children are
#     untagged too). deploy.sh refuses an image without its signature, so a rollback
#     target that lost it could not be redeployed.
# So the keep set is: the N newest semver-tagged versions, their children, the
# signature/attestation tags of every kept digest, and those tags' children.
# Deleted: older semver versions, signature tags of digests that are gone, and
# untagged versions nothing kept refers to. Other tags (a hand-pushed `main`) are left.
#
# Nothing younger than --min-age-hours is deleted: image.yml pushes by digest, scans,
# and only then tags, so a release in flight is briefly an untagged version.

set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then echo "ghcr-retention needs bash >= 4" >&2; exit 1; fi

OWNER="${1:?usage: ghcr-retention.sh <owner> <package> [--keep N] [--min-age-hours H] [--apply]}"
PACKAGE="${2:?package}"
shift 2
KEEP=10
MIN_AGE_HOURS=24
APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP="$2"; shift 2 ;;
    --min-age-hours) MIN_AGE_HOURS="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$KEEP" =~ ^[0-9]+$ && "$KEEP" -ge 1 ]] || { echo "--keep must be a positive integer" >&2; exit 2; }
[[ "$MIN_AGE_HOURS" =~ ^[0-9]+$ ]] || { echo "--min-age-hours must be an integer" >&2; exit 2; }

# Releases (1.2.3) and builds of main (main-<sha7>) both count as versions to keep.
SEMVER_RE='^([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?|main-[0-9a-f]{7})$'
REFERRER_RE='^sha256-[0-9a-f]{64}(\..+)?$'

# Test hooks: a fixture instead of the API / the registry.
if [ -n "${RETENTION_VERSIONS_FILE:-}" ]; then
  versions="$(cat "$RETENTION_VERSIONS_FILE")"
else
  versions="$(gh api --paginate "/orgs/${OWNER}/packages/container/${PACKAGE}/versions?per_page=100" | jq -s 'add // []')"
fi

# Child manifest digests of one digest (empty for a single-platform image).
children() {
  if [ -n "${RETENTION_CHILDREN_FILE:-}" ]; then
    jq -r --arg d "$1" '.[$d] // [] | .[]' "$RETENTION_CHILDREN_FILE"
  else
    docker buildx imagetools inspect --raw "ghcr.io/${OWNER}/${PACKAGE}@$1" | jq -r '(.manifests // [])[].digest'
  fi
}

declare -A keep_set=()
keep_digest() { # digest -> add it and its children
  local d="$1" c
  [ -z "${keep_set[$d]:-}" ] || return 0
  keep_set[$d]=1
  while read -r c; do [ -z "$c" ] || keep_set[$c]=1; done < <(children "$d")
}

# 1. The N newest semver-tagged versions.
mapfile -t newest < <(jq -r --argjson keep "$KEEP" --arg re "$SEMVER_RE" '
  [ .[] | select(any(.metadata.container.tags[]?; test($re))) ]
  | sort_by(.created_at) | reverse | .[:$keep] | .[].name' <<<"$versions")

if [ "${#newest[@]}" -eq 0 ]; then
  echo "${PACKAGE}: no semver-tagged version: nothing is deleted"
  exit 0
fi
for d in "${newest[@]}"; do keep_digest "$d"; done

# 2. Signature / attestation tags of every digest kept so far (and their children).
mapfile -t referrers < <(jq -r --arg re "$REFERRER_RE" '
  .[] | select(any(.metadata.container.tags[]?; test($re)))
  | [.name, (.metadata.container.tags[] | select(test($re)))] | @tsv' <<<"$versions")
for line in "${referrers[@]}"; do
  [ -n "$line" ] || continue
  name="${line%%$'\t'*}"
  for tag in ${line#*$'\t'}; do
    target="sha256:${tag#sha256-}"; target="${target%%.*}"
    if [ -n "${keep_set[$target]:-}" ]; then keep_digest "$name"; fi
  done
done

# 3. Everything else that is old enough and of a kind this script owns.
now="$(date +%s)"
deleted=0 kept=0
while IFS=$'\t' read -r id name kind age_h; do
  [ -n "$id" ] || continue
  if [ -n "${keep_set[$name]:-}" ] || [ "$kind" = other ] || [ "$age_h" -lt "$MIN_AGE_HOURS" ]; then
    kept=$((kept + 1)); continue
  fi
  deleted=$((deleted + 1))
  if [ "$APPLY" = 1 ]; then
    echo "delete ${PACKAGE} version ${id} (${kind}) ${name}"
    if [ -n "${RETENTION_VERSIONS_FILE:-}" ]; then :; else
      gh api -X DELETE "/orgs/${OWNER}/packages/container/${PACKAGE}/versions/${id}" >/dev/null
    fi
  else
    echo "would delete ${PACKAGE} version ${id} (${kind}) ${name}"
  fi
done < <(jq -r --argjson now "$now" --arg semver "$SEMVER_RE" --arg ref "$REFERRER_RE" '
  .[] | . as $v | ($v.metadata.container.tags // []) as $t
  | [ $v.id, $v.name,
      (if ($t | length) == 0 then "untagged"
       elif any($t[]; test($semver)) then "release"
       elif any($t[]; test($ref)) then "signature"
       else "other" end),
      ((($now - ($v.created_at | fromdateiso8601)) / 3600) | floor) ]
  | @tsv' <<<"$versions")

echo "${PACKAGE}: keeping ${kept}, $([ "$APPLY" = 1 ] && echo deleted || echo "would delete") ${deleted}"
