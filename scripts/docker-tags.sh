#!/bin/sh
set -eu

if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
  echo "usage: $0 IMAGE CHANNEL OPENLDAP_VERSION ALPINE_VERSION [RELEASE_TAG]" >&2
  exit 2
fi

image_name="$1"
channel="$2"
openldap_version="$3"
alpine_version="$4"
release_tag="${5:-}"
openldap_series="${openldap_version%.*}"

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
  "${image_name}:${openldap_version}-alpine${alpine_version}"

if [ "$channel" = lts ]; then
  printf '%s\n' "${image_name}:latest"
fi

if [ -n "$release_tag" ]; then
  case "$release_tag" in
    "${openldap_version}"-r*) printf '%s\n' "${image_name}:${release_tag}" ;;
    *)
      echo "release tag ${release_tag} does not match OpenLDAP ${openldap_version}" >&2
      exit 2
      ;;
  esac
fi
