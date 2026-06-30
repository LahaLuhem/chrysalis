#!/usr/bin/env bash
#
# Assert that a published multi-arch image uses OCI media types throughout: the index, both
# expected arches, and every per-arch image manifest plus its config and layers. Exits non-zero on
# the first non-OCI media type. build-image.yml's merge job runs this against the pushed image after
# a publish; it's also runnable locally against any registry ref, e.g.
#
#   ./scripts/assert_oci_registry.sh ghcr.io/lahaluhem/android-sdk:latest
#
# Reads manifests with `docker buildx imagetools inspect --raw` and parses with jq.
set -euo pipefail

ref="${1:?usage: assert_oci_registry.sh <image-ref>}"

oci_index="application/vnd.oci.image.index.v1+json"
oci_manifest="application/vnd.oci.image.manifest.v1+json"
oci_config="application/vnd.oci.image.config.v1+json"
oci_layer_prefix="application/vnd.oci.image.layer."

fail() { echo "FAIL ($ref): $1" >&2; exit 1; }

index="$(docker buildx imagetools inspect "$ref" --raw)"

# The top-level object must be an OCI image index.
mt="$(jq -r '.mediaType // empty' <<<"$index")"
[ "$mt" = "$oci_index" ] || fail "index mediaType is '${mt:-<none>}', want '$oci_index'"

# Both arches must be present.
for plat in linux/amd64 linux/arm64; do
  jq -e --arg p "$plat" '.manifests[] | select((.platform.os + "/" + .platform.architecture) == $p)' \
    <<<"$index" >/dev/null || fail "index is missing $plat"
done

# Every image-manifest child (skip any non-image entries, e.g. attestation/unknown) plus its config
# and layers must be OCI too. Digests are one per line with no spaces, so word-splitting is safe.
digests="$(jq -r '.manifests[] | select(.platform.os != "unknown") | .digest' <<<"$index")"
[ -n "$digests" ] || fail "index has no image manifests"

for d in $digests; do
  child="$(docker buildx imagetools inspect "${ref}@${d}" --raw)"
  cmt="$(jq -r '.mediaType // empty' <<<"$child")"
  [ "$cmt" = "$oci_manifest" ] || fail "manifest $d mediaType is '${cmt:-<none>}', want '$oci_manifest'"
  cfg="$(jq -r '.config.mediaType // empty' <<<"$child")"
  [ "$cfg" = "$oci_config" ] || fail "config of $d is '${cfg:-<none>}', want '$oci_config'"
  bad="$(jq -r --arg p "$oci_layer_prefix" '.layers[]? | select((.mediaType | startswith($p)) | not) | .mediaType' <<<"$child" | head -n1)"
  [ -z "$bad" ] || fail "layer of $d is '$bad', want '${oci_layer_prefix}*'"
done

echo "OK ($ref): OCI index + $(wc -w <<<"$digests" | tr -d ' ') arch manifests, configs, and layers all use OCI media types"
