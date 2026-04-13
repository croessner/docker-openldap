#!/bin/sh
set -eu
exec ldapsearch -Q -Y EXTERNAL -H "${LDAP_LDAPI_URI:-ldapi://%2Fvar%2Frun%2Fopenldap%2Fldapi}" -LLL -s base -b "" namingContexts >/dev/null 2>&1
