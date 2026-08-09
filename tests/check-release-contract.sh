#!/bin/sh
# shellcheck disable=SC1091
set -eu

repo_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_root"

. versions/alpine.env
. versions/openldap-lts.env
lts_version="$OPENLDAP_VERSION"
lts_sha256="$OPENLDAP_SHA256"
lts_tags="$(scripts/docker-tags.sh example/openldap lts "$lts_version" "$ALPINE_VERSION")"

. versions/openldap-stable.env
stable_version="$OPENLDAP_VERSION"
stable_tags="$(scripts/docker-tags.sh example/openldap stable "$stable_version" "$ALPINE_VERSION")"

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
assert_tag "$lts_tags" "example/openldap:latest"

assert_tag "$stable_tags" "example/openldap:${stable_version}"
assert_tag "$stable_tags" "example/openldap:${stable_version%.*}"
assert_tag "$stable_tags" "example/openldap:${stable_version%.*}-stable"
assert_tag "$stable_tags" "example/openldap:stable"
reject_tag "$stable_tags" "example/openldap:latest"

grep -Fx "ARG ALPINE_VERSION=${ALPINE_VERSION}" Dockerfile >/dev/null
grep -Fx 'ARG OPENLDAP_CHANNEL=lts' Dockerfile >/dev/null
grep -Fx "ARG OPENLDAP_VERSION=${lts_version}" Dockerfile >/dev/null
grep -Fx "ARG OPENLDAP_SHA256=${lts_sha256}" Dockerfile >/dev/null
# shellcheck disable=SC2016
grep -F '`latest` deliberately remains on LTS' README.md >/dev/null

echo "release contract OK: latest is LTS-only; stable is independently tagged"
