#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 MANIFEST bump|reset" >&2
  exit 2
fi

manifest="$1"
mode="$2"
current_revision="$(sed -n 's/^IMAGE_REVISION=//p' "$manifest")"

case "$current_revision" in
  ''|*[!0-9]*|0)
    echo "invalid IMAGE_REVISION in ${manifest}: ${current_revision:-missing}" >&2
    exit 2
    ;;
esac

case "$mode" in
  bump) new_revision=$((current_revision + 1)) ;;
  reset) new_revision=1 ;;
  *)
    echo "unsupported revision mode: $mode" >&2
    exit 2
    ;;
esac

sed -i.bak "s/^IMAGE_REVISION=.*/IMAGE_REVISION=${new_revision}/" "$manifest"
rm -f "${manifest}.bak"
printf '%s\n' "$new_revision"
