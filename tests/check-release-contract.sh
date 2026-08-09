#!/bin/sh
# shellcheck disable=SC1091
set -eu

repo_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_root"

. versions/alpine.env
. versions/openldap-lts.env
lts_version="$OPENLDAP_VERSION"
lts_sha256="$OPENLDAP_SHA256"
lts_revision="$IMAGE_REVISION"
lts_tags="$(scripts/docker-tags.sh example/openldap lts "$lts_version" "$lts_revision" "$ALPINE_VERSION")"

. versions/openldap-stable.env
stable_version="$OPENLDAP_VERSION"
stable_revision="$IMAGE_REVISION"
stable_tags="$(scripts/docker-tags.sh example/openldap stable "$stable_version" "$stable_revision" "$ALPINE_VERSION")"

assert_tag() {
  tags="$1"
  expected="$2"
  printf '%s\n' "$tags" | grep -Fx "$expected" >/dev/null
}

reject_tag() {
  tags="$1"
  rejected="$2"
  if printf '%s\n' "$tags" | grep -Fx "$rejected" >/dev/null; then
    echo "unexpected tag: $rejected" >&2
    exit 1
  fi
}

assert_tag "$lts_tags" "example/openldap:${lts_version}"
assert_tag "$lts_tags" "example/openldap:${lts_version%.*}"
assert_tag "$lts_tags" "example/openldap:${lts_version%.*}-lts"
assert_tag "$lts_tags" "example/openldap:lts"
assert_tag "$lts_tags" "example/openldap:${lts_version}-r${lts_revision}"
assert_tag "$lts_tags" "example/openldap:latest"

assert_tag "$stable_tags" "example/openldap:${stable_version}"
assert_tag "$stable_tags" "example/openldap:${stable_version%.*}"
assert_tag "$stable_tags" "example/openldap:${stable_version%.*}-stable"
assert_tag "$stable_tags" "example/openldap:stable"
assert_tag "$stable_tags" "example/openldap:${stable_version}-r${stable_revision}"
reject_tag "$stable_tags" "example/openldap:latest"

grep -Fx "ARG ALPINE_VERSION=${ALPINE_VERSION}" Dockerfile >/dev/null
grep -Fx "ARG ALPINE_DIGEST=${ALPINE_DIGEST}" Dockerfile >/dev/null
grep -Fx 'ARG OPENLDAP_CHANNEL=lts' Dockerfile >/dev/null
grep -Fx "ARG OPENLDAP_VERSION=${lts_version}" Dockerfile >/dev/null
grep -Fx "ARG OPENLDAP_SHA256=${lts_sha256}" Dockerfile >/dev/null
grep -Fx "ARG IMAGE_REVISION=${lts_revision}" Dockerfile >/dev/null
# shellcheck disable=SC2016
grep -F '`latest` deliberately remains on LTS' README.md >/dev/null

temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT INT TERM
cp versions/openldap-lts.env "$temp_dir/lts.env"
test "$(scripts/bump-image-revision.sh "$temp_dir/lts.env" bump)" -eq $((lts_revision + 1))
grep -Fx "IMAGE_REVISION=$((lts_revision + 1))" "$temp_dir/lts.env" >/dev/null
test "$(scripts/bump-image-revision.sh "$temp_dir/lts.env" reset)" -eq 1
grep -Fx 'IMAGE_REVISION=1' "$temp_dir/lts.env" >/dev/null

scripts/docker-tags.sh example/openldap lts "$lts_version" "$lts_revision" "$ALPINE_VERSION" "${lts_version}-r${lts_revision}" >/dev/null
if scripts/docker-tags.sh example/openldap lts "$lts_version" "$lts_revision" "$ALPINE_VERSION" "${lts_version}-r999" >/dev/null 2>&1; then
  echo "mismatched release revision was accepted" >&2
  exit 1
fi

echo "release contract OK: latest is LTS-only; both channels have pinned -rX tags"
