#!/bin/sh
set -eu

# VARIANT selects the base distribution: alpine (default) or debian. The Alpine
# tags keep their historical names; every Debian tag carries a -debian suffix.
if [ "$#" -lt 5 ] || [ "$#" -gt 6 ]; then
  echo "usage: [VARIANT=alpine|debian] $0 IMAGE CHANNEL OPENLDAP_VERSION IMAGE_REVISION BASE_VERSION [RELEASE_TAG]" >&2
  exit 2
fi

image_name="$1"
channel="$2"
openldap_version="$3"
image_revision="$4"
base_version="$5"
release_tag="${6:-}"
variant="${VARIANT:-alpine}"
openldap_series="${openldap_version%.*}"

case "$variant" in
  alpine) suffix="" ;;
  debian) suffix="-debian" ;;
  *)
    echo "unsupported image variant: $variant" >&2
    exit 2
    ;;
esac

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
  "${image_name}:${openldap_version}${suffix}" \
  "${image_name}:${openldap_series}${suffix}" \
  "${image_name}:${openldap_series}-${channel}${suffix}" \
  "${image_name}:${channel}${suffix}" \
  "${image_name}:${openldap_version}-${variant}${base_version}" \
  "${image_name}:${revision_tag}${suffix}"

# latest stays the Alpine LTS image; the Debian variant is always chosen explicitly.
if [ "$channel" = lts ] && [ "$variant" = alpine ]; then
  printf '%s\n' "${image_name}:latest"
fi

if [ -n "$release_tag" ]; then
  if [ "$release_tag" != "$revision_tag" ]; then
    echo "release tag ${release_tag} does not match image revision ${revision_tag}" >&2
    exit 2
  fi
fi
