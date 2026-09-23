#!/bin/sh
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 IMAGE CHANNEL [alpine|debian]" >&2
  exit 2
fi

image="$1"
channel="$2"
variant="${3:-alpine}"
container_name="openldap-${channel}-${variant}-smoke-$$"

# The ODBC runtime that back_sql needs has a different package name per base.
case "$variant" in
  alpine) odbc_installed='apk info -e unixodbc >/dev/null 2>&1' ;;
  debian) odbc_installed='dpkg -s libodbc2 >/dev/null 2>&1' ;;
  *)
    echo "unsupported image variant: $variant" >&2
    exit 2
    ;;
esac

cleanup() {
  docker rm -f "$container_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

case "$channel" in
  lts)
    docker run --rm --entrypoint /bin/sh "$image" -ec "
      ${odbc_installed}
      test -e /usr/lib/openldap/openldap/back_sql.so
      test ! -e /usr/lib/openldap/openldap/back_perl.so
    "
    ;;
  stable)
    docker run --rm --entrypoint /bin/sh "$image" -ec "
      if ${odbc_installed}; then exit 1; fi
      test ! -e /usr/lib/openldap/openldap/back_sql.so
      test ! -e /usr/lib/openldap/openldap/back_perl.so
    "
    ;;
  *)
    echo "unsupported OpenLDAP channel: $channel" >&2
    exit 2
    ;;
esac

docker run -d --rm \
  --name "$container_name" \
  --env LDAP_DOMAIN="${channel}.example.test" \
  --env LDAP_ADMIN_PASSWORD=smoke-test-only \
  "$image" >/dev/null

ready=false
attempt=0
while [ "$attempt" -lt 30 ]; do
  # Bootstrap starts a temporary slapd that also answers the health check.
  # Wait for the entrypoint to exec the final server before testing readiness.
  if docker exec "$container_name" /bin/sh -ec '
    test "$(cat /proc/1/comm)" = slapd
    docker-healthcheck.sh
  '; then
    ready=true
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done

if [ "$ready" != true ]; then
  docker logs "$container_name" >&2
  exit 1
fi

docker exec "$container_name" \
  ldapsearch -Q -Y EXTERNAL \
  -H ldapi://%2Fvar%2Frun%2Fopenldap%2Fldapi \
  -LLL -s base -b '' namingContexts |
  grep -Fx "namingContexts: dc=${channel},dc=example,dc=test" >/dev/null

docker stop "$container_name" >/dev/null
trap - EXIT INT TERM
