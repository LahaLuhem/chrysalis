#!/usr/bin/env bash
#
# Assert that an OCI image layout (as written by `docker buildx build --output type=oci,tar=false`)
# uses OCI media types throughout: the layout index, every image manifest it points to (recursing
# through any nested index), and each manifest's config and layers. Exits non-zero on the first
# non-OCI media type. build-image.yml runs this at PR time (the amd64 leg) against a freshly built
# layout, before anything is published; also runnable locally:
#
#   ./scripts/assert_oci_layout.sh path/to/oci-layout
#
set -euo pipefail

dir="${1:?usage: assert_oci_layout.sh <oci-layout-dir>}"
[ -f "$dir/index.json" ] || { echo "FAIL: $dir/index.json not found (not an OCI layout?)" >&2; exit 1; }

oci_index="application/vnd.oci.image.index.v1+json"
oci_manifest="application/vnd.oci.image.manifest.v1+json"
oci_config="application/vnd.oci.image.config.v1+json"
oci_layer_prefix="application/vnd.oci.image.layer."

fail() { echo "FAIL ($dir): $1" >&2; exit 1; }

# Filesystem path of a blob given its "sha256:<hex>" digest.
blob() { printf '%s/blobs/%s/%s' "$dir" "${1%%:*}" "${1#*:}"; }

manifests=0

# Validate one descriptor (mediaType + digest), recursing into nested indexes.
walk() {
  local mt="$1" dg="$2" f cfg bad
  f="$(blob "$dg")"
  [ -f "$f" ] || fail "blob for $dg is missing"
  case "$mt" in
    "$oci_index")
      while read -r cmt cdg; do
        [ -n "$cmt" ] && walk "$cmt" "$cdg"
      done < <(jq -r '.manifests[] | "\(.mediaType) \(.digest)"' "$f")
      ;;
    "$oci_manifest")
      manifests=$((manifests + 1))
      cfg="$(jq -r '.config.mediaType // empty' "$f")"
      [ "$cfg" = "$oci_config" ] || fail "manifest $dg config is '${cfg:-<none>}', want '$oci_config'"
      bad="$(jq -r --arg p "$oci_layer_prefix" '.layers[]? | select((.mediaType | startswith($p)) | not) | .mediaType' "$f" | head -n1)"
      [ -z "$bad" ] || fail "manifest $dg layer is '$bad', want '${oci_layer_prefix}*'"
      ;;
    *)
      fail "unexpected descriptor mediaType '$mt' (want an OCI index or manifest)"
      ;;
  esac
}

top_mt="$(jq -r '.mediaType // empty' "$dir/index.json")"
[ "$top_mt" = "$oci_index" ] || fail "layout index mediaType is '${top_mt:-<none>}', want '$oci_index'"

while read -r cmt cdg; do
  [ -n "$cmt" ] && walk "$cmt" "$cdg"
done < <(jq -r '.manifests[] | "\(.mediaType) \(.digest)"' "$dir/index.json")

[ "$manifests" -gt 0 ] || fail "no image manifests found in layout"
echo "OK ($dir): OCI layout index + $manifests image manifest(s), configs, and layers all use OCI media types"
