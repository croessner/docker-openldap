#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 IMAGE CHANNEL" >&2
  exit 2
fi

image="$1"
channel="$2"
container_name="openldap-${channel}-smoke-$$"

cleanup() {
  docker rm -f "$container_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

case "$channel" in
  lts)
    docker run --rm --entrypoint /bin/sh "$image" -ec '
      apk info -e unixodbc >/dev/null
      test -e /usr/lib/openldap/openldap/back_sql.so
      test ! -e /usr/lib/openldap/openldap/back_perl.so
    '
    ;;
  stable)
    docker run --rm --entrypoint /bin/sh "$image" -ec '
      if apk info -e unixodbc >/dev/null 2>&1; then exit 1; fi
      test ! -e /usr/lib/openldap/openldap/back_sql.so
      test ! -e /usr/lib/openldap/openldap/back_perl.so
    '
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
  if docker exec "$container_name" docker-healthcheck.sh; then
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
