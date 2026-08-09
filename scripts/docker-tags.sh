#!/bin/sh
set -eu

if [ "$#" -lt 5 ] || [ "$#" -gt 6 ]; then
  echo "usage: $0 IMAGE CHANNEL OPENLDAP_VERSION IMAGE_REVISION ALPINE_VERSION [RELEASE_TAG]" >&2
  exit 2
fi

image_name="$1"
channel="$2"
openldap_version="$3"
image_revision="$4"
alpine_version="$5"
release_tag="${6:-}"
openldap_series="${openldap_version%.*}"

case "$image_revision" in
  ''|*[!0-9]*|0)
    echo "invalid image revision: $image_revision" >&2
    exit 2
    ;;
esac

revision_tag="${openldap_version}-r${image_revision}"

case "$channel" in
  lts|stable) ;;
  *)
    echo "unsupported OpenLDAP channel: $channel" >&2
    exit 2
    ;;
esac

printf '%s\n' \
  "${image_name}:${openldap_version}" \
  "${image_name}:${openldap_series}" \
  "${image_name}:${openldap_series}-${channel}" \
  "${image_name}:${channel}" \
  "${image_name}:${openldap_version}-alpine${alpine_version}" \
  "${image_name}:${revision_tag}"

if [ "$channel" = lts ]; then
  printf '%s\n' "${image_name}:latest"
fi

if [ -n "$release_tag" ]; then
  if [ "$release_tag" != "$revision_tag" ]; then
    echo "release tag ${release_tag} does not match image revision ${revision_tag}" >&2
    exit 2
  fi
fi
