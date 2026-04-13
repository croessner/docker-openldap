#!/bin/sh
set -eu

log() {
  printf '%s %s\n' '[openldap-entrypoint]' "$*"
}

warn() {
  printf '%s %s\n' '[openldap-entrypoint][warn]' "$*" >&2
}

die() {
  printf '%s %s\n' '[openldap-entrypoint][error]' "$*" >&2
  exit 1
}

bool_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

file_env() {
  var="$1"
  default="${2:-}"
  file_var="${var}_FILE"

  eval "var_value=\${$var:-}"
  eval "file_value=\${$file_var:-}"

  if [ -n "${var_value}" ] && [ -n "${file_value}" ]; then
    die "Both ${var} and ${file_var} are set. Please use only one."
  fi

  if [ -n "${file_value}" ]; then
    [ -r "${file_value}" ] || die "Cannot read ${file_var} path: ${file_value}"
    var_value="$(cat "${file_value}")"
  fi

  if [ -z "${var_value}" ]; then
    var_value="${default}"
  fi

  export "${var}=${var_value}"
  unset "${file_var}" || true
}

domain_to_base_dn() {
  domain="$1"
  old_ifs="$IFS"
  IFS='.'
  set -- $domain
  IFS="$old_ifs"

  out=''
  for label in "$@"; do
    [ -n "$label" ] || continue
    label="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
    if [ -z "$out" ]; then
      out="dc=$label"
    else
      out="$out,dc=$label"
    fi
  done
  printf '%s' "$out"
}

first_rdn_attr() {
  dn="$1"
  first="${dn%%,*}"
  printf '%s' "${first%%=*}" | tr '[:upper:]' '[:lower:]'
}

first_rdn_value() {
  dn="$1"
  first="${dn%%,*}"
  printf '%s' "${first#*=}"
}

default_org_from_dn() {
  dn="$1"
  case "$(first_rdn_attr "$dn")" in
    dc|o|ou|cn) first_rdn_value "$dn" ;;
    *) printf '%s' 'Example Inc.' ;;
  esac
}

normalize_module_name() {
  mod="$1"
  case "$mod" in
    *.so|*.la) printf '%s' "$mod" ;;
    *) printf '%s.so' "$mod" ;;
  esac
}

ensure_dir() {
  dir="$1"
  owner="$2"
  group="$3"
  mode="$4"

  mkdir -p "$dir"
  chown "$owner:$group" "$dir"
  chmod "$mode" "$dir"
}

append_sorted_dir() {
  dir="$1"
  pattern="$2"
  if [ ! -d "$dir" ]; then
    return 0
  fi

  found=0
  for file in "$dir"/$pattern; do
    [ -e "$file" ] || continue
    found=1
    printf '\n# --- begin %s ---\n' "$file"
    cat "$file"
    printf '\n# --- end %s ---\n' "$file"
  done

  [ "$found" -eq 1 ] || return 0
}

init_file_type() {
  file="$1"
  if grep -Eiq '^[[:space:]]*changetype[[:space:]]*:' "$file"; then
    printf '%s' 'modify'
  else
    printf '%s' 'add'
  fi
}

initdb_has_entries() {
  if [ ! -d "${LDAP_INITDB_DIR}" ]; then
    return 1
  fi

  if find "${LDAP_INITDB_DIR}" -mindepth 1 -maxdepth 1 | read -r _; then
    return 0
  fi

  return 1
}

render_schema_includes() {
  printf 'include %s/core.schema\n' "${LDAP_SCHEMA_DIR}"

  for schema in $(printf '%s' "${LDAP_EXTRA_SCHEMAS}" | tr ',' ' '); do
    [ -n "$schema" ] || continue
    case "$schema" in
      core|core.schema) continue ;;
      *.schema|/*) printf 'include %s\n' "$schema" ;;
      *) printf 'include %s/%s.schema\n' "${LDAP_SCHEMA_DIR}" "$schema" ;;
    esac
  done

  if bool_true "${LDAP_ENABLE_ACCESSLOG}"; then
    printf 'include %s/audit.schema\n' "${LDAP_SCHEMA_DIR}"
  fi

  if [ -d "${LDAP_CUSTOM_SCHEMA_DIR}" ]; then
    for schema in "${LDAP_CUSTOM_SCHEMA_DIR}"/*.schema; do
      [ -e "$schema" ] || continue
      printf 'include %s\n' "$schema"
    done
  fi
}

render_module_loads() {
  tmp_modules="$(mktemp)"
  trap 'rm -f "$tmp_modules"' EXIT INT TERM

  printf '%s\n' "back_mdb.so" > "$tmp_modules"

  if bool_true "${LDAP_ENABLE_ACCESSLOG}"; then
    printf '%s\n' "accesslog.so" >> "$tmp_modules"
  fi
  if bool_true "${LDAP_ENABLE_MEMBEROF}"; then
    printf '%s\n' "memberof.so" >> "$tmp_modules"
  fi
  if bool_true "${LDAP_ENABLE_REFINT}"; then
    printf '%s\n' "refint.so" >> "$tmp_modules"
  fi
  if bool_true "${LDAP_ENABLE_SYNCPROV}"; then
    printf '%s\n' "syncprov.so" >> "$tmp_modules"
  fi

  for mod in $(printf '%s' "${LDAP_LOAD_MODULES}" | tr ',' ' '); do
    [ -n "$mod" ] || continue
    normalize_module_name "$mod" >> "$tmp_modules"
    printf '\n' >> "$tmp_modules"
  done

  printf 'modulepath %s\n' "$LDAP_MODULE_PATH"
  sort -u "$tmp_modules" | while IFS= read -r mod; do
    [ -n "$mod" ] || continue
    printf 'moduleload %s\n' "$mod"
  done

  rm -f "$tmp_modules"
  trap - EXIT INT TERM
}

render_tls_block() {
  if ! bool_true "${LDAP_ENABLE_TLS}"; then
    return 0
  fi

  [ -n "${LDAP_TLS_CERT_FILE}" ] || die "LDAP_ENABLE_TLS=true requires LDAP_TLS_CERT_FILE"
  [ -n "${LDAP_TLS_KEY_FILE}" ] || die "LDAP_ENABLE_TLS=true requires LDAP_TLS_KEY_FILE"
  [ -n "${LDAP_TLS_CA_FILE}" ] || die "LDAP_ENABLE_TLS=true requires LDAP_TLS_CA_FILE"

  for f in "${LDAP_TLS_CERT_FILE}" "${LDAP_TLS_KEY_FILE}" "${LDAP_TLS_CA_FILE}"; do
    [ -r "$f" ] || die "TLS file is missing or unreadable: $f"
    su-exec ldap:ldap test -r "$f" || die "TLS file must be readable by ldap user: $f"
  done

  printf 'TLSCACertificateFile %s\n' "$LDAP_TLS_CA_FILE"
  printf 'TLSCertificateFile %s\n' "$LDAP_TLS_CERT_FILE"
  printf 'TLSCertificateKeyFile %s\n' "$LDAP_TLS_KEY_FILE"

  if [ -n "${LDAP_TLS_DH_PARAM_FILE}" ]; then
    [ -r "${LDAP_TLS_DH_PARAM_FILE}" ] || die "Cannot read LDAP_TLS_DH_PARAM_FILE: ${LDAP_TLS_DH_PARAM_FILE}"
    su-exec ldap:ldap test -r "${LDAP_TLS_DH_PARAM_FILE}" || die "DH param file must be readable by ldap user: ${LDAP_TLS_DH_PARAM_FILE}"
    printf 'TLSDHParamFile %s\n' "$LDAP_TLS_DH_PARAM_FILE"
  fi

  if [ -n "${LDAP_TLS_CIPHER_SUITE}" ]; then
    printf 'TLSCipherSuite %s\n' "$LDAP_TLS_CIPHER_SUITE"
  fi

  if [ -n "${LDAP_TLS_VERIFY_CLIENT}" ]; then
    printf 'TLSVerifyClient %s\n' "$LDAP_TLS_VERIFY_CLIENT"
  fi
}

render_monitor_db() {
  if ! bool_true "${LDAP_ENABLE_MONITOR_DB}"; then
    return 0
  fi

  cat <<EOF
database monitor
access to *
    by dn.exact="${LDAP_ADMIN_DN}" read
    by * none

EOF
}

render_accesslog_db() {
  if ! bool_true "${LDAP_ENABLE_ACCESSLOG}"; then
    return 0
  fi

  cat <<EOF
database    mdb
maxsize     ${LDAP_ACCESSLOG_MAXSIZE}
suffix      "${LDAP_ACCESSLOG_SUFFIX}"
rootdn      "${LDAP_ACCESSLOG_ROOTDN}"
directory   ${LDAP_ACCESSLOG_DB_DIR}
index       default eq
index       entryCSN,objectClass,reqEnd,reqResult,reqStart,reqDN eq
access to *
    by dn.exact="${LDAP_ADMIN_DN}" read
    by * none

EOF
}

render_main_db() {
  cat <<EOF
database    mdb
maxsize     ${LDAP_MDB_MAXSIZE}
suffix      "${LDAP_BASE_DN}"
rootdn      "${LDAP_ADMIN_DN}"
rootpw      ${LDAP_ADMIN_PASSWORD_HASH}
directory   ${LDAP_DB_DIR}
checkpoint  ${LDAP_MDB_CHECKPOINT}
index       objectClass eq
index       uid,cn,sn,mail,givenName eq,sub
index       member,memberUid eq
index       uidNumber,gidNumber eq
index       entryUUID,entryCSN eq

EOF

  if bool_true "${LDAP_MDB_DBNOSYNC}"; then
    printf '%s\n\n' 'dbnosync'
  fi

  if bool_true "${LDAP_ENABLE_SYNCPROV}"; then
    printf '%s\n' 'overlay syncprov'
    printf 'syncprov-checkpoint %s\n' "${LDAP_SYNCPROV_CHECKPOINT}"
    if [ -n "${LDAP_SYNCPROV_SESSIONLOG}" ]; then
      printf 'syncprov-sessionlog %s\n' "${LDAP_SYNCPROV_SESSIONLOG}"
    fi
    printf '\n'
  fi

  if bool_true "${LDAP_ENABLE_ACCESSLOG}"; then
    printf '%s\n' 'overlay accesslog'
    printf 'logdb %s\n' "${LDAP_ACCESSLOG_SUFFIX}"
    printf 'logops %s\n' "${LDAP_ACCESSLOG_LOGOPS}"
    printf '%s\n' 'logsuccess TRUE'
    if [ -n "${LDAP_ACCESSLOG_LOGPURGE}" ]; then
      printf 'logpurge %s\n' "${LDAP_ACCESSLOG_LOGPURGE}"
    fi
    printf '\n'
  fi

  if bool_true "${LDAP_ENABLE_MEMBEROF}"; then
    printf '%s\n' 'overlay memberof'
    printf '%s\n' 'memberof-group-oc groupOfNames'
    printf '%s\n' 'memberof-member-ad member'
    printf '%s\n\n' 'memberof-memberof-ad memberOf'
  fi

  if bool_true "${LDAP_ENABLE_REFINT}"; then
    printf '%s\n' 'overlay refint'
    printf '%s\n\n' 'refint_attributes member memberOf manager owner'
  fi

  cat <<EOF
access to attrs=userPassword
    by self write
    by anonymous auth
    by dn.exact="${LDAP_ADMIN_DN}" write
    by * none

access to attrs=shadowLastChange
    by self write
    by dn.exact="${LDAP_ADMIN_DN}" write
    by * read

access to *
    by dn.exact="${LDAP_ADMIN_DN}" write
    by users read
    by * none

EOF
}

write_config() {
  tmp_conf="$(mktemp)"
  trap 'rm -f "$tmp_conf"' EXIT INT TERM

  {
    printf '%s\n' '# This file is generated at container start.'
    printf '%s\n' '# Mount your own slapd.conf and set LDAP_SKIP_DEFAULT_CONFIG=true to fully bypass generation.'
    printf '\n'

    render_schema_includes
    printf '\n'
    render_module_loads
    printf '\n'

    printf 'pidfile %s/slapd.pid\n' "${LDAP_RUN_DIR}"
    printf 'argsfile %s/slapd.args\n' "${LDAP_RUN_DIR}"
    printf 'loglevel %s\n' "${LDAP_LOG_LEVEL}"

    if [ -n "${LDAP_THREADS}" ]; then
      printf 'threads %s\n' "${LDAP_THREADS}"
    fi

    if [ -n "${LDAP_TIMELIMIT}" ]; then
      printf 'timelimit %s\n' "${LDAP_TIMELIMIT}"
    fi

    if [ -n "${LDAP_SIZELIMIT}" ]; then
      printf 'sizelimit %s\n' "${LDAP_SIZELIMIT}"
    fi

    if ! bool_true "${LDAP_ALLOW_ANON_BIND}"; then
      printf '%s\n' 'disallow bind_anon'
    fi

    if bool_true "${LDAP_REQUIRE_TLS}"; then
      printf 'security simple_bind=%s\n' "${LDAP_SIMPLE_BIND_MIN_SSF}"
    fi

    if bool_true "${LDAP_ENABLE_PEERCRED_ADMIN}"; then
      printf 'authz-regexp "%s" "%s"\n' '^gidNumber=0\+uidNumber=0,cn=peercred,cn=external,cn=auth$' "${LDAP_ADMIN_DN}"
    fi

    render_tls_block
    append_sorted_dir "${LDAP_CUSTOM_PRECONFIG_DIR}" '*.conf'
    printf '\n'
    render_monitor_db
    render_accesslog_db
    render_main_db
    append_sorted_dir "${LDAP_CUSTOM_POSTCONFIG_DIR}" '*.conf'
  } > "${tmp_conf}"

  mv "${tmp_conf}" "${LDAP_CONF}"
  chmod 0644 "${LDAP_CONF}"
  trap - EXIT INT TERM
}

bootstrap_base_ldif() {
  tmp_ldif="$(mktemp)"

  base_attr="$(first_rdn_attr "${LDAP_BASE_DN}")"
  base_value="$(first_rdn_value "${LDAP_BASE_DN}")"

  case "${base_attr}" in
    dc)
      cat > "${tmp_ldif}" <<EOF
dn: ${LDAP_BASE_DN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${LDAP_ORGANISATION}
dc: ${base_value}

EOF
      ;;
    o)
      cat > "${tmp_ldif}" <<EOF
dn: ${LDAP_BASE_DN}
objectClass: top
objectClass: organization
o: ${base_value}

EOF
      ;;
    ou)
      cat > "${tmp_ldif}" <<EOF
dn: ${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: ${base_value}

EOF
      ;;
    cn)
      cat > "${tmp_ldif}" <<EOF
dn: ${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalRole
cn: ${base_value}

EOF
      ;;
    *)
      die "Automatic base entry generation only supports base DN starting with dc=, o=, ou= or cn=. Current value: ${LDAP_BASE_DN}"
      ;;
  esac

  if bool_true "${LDAP_CREATE_ADMIN_ENTRY}"; then
    cat >> "${tmp_ldif}" <<EOF
dn: ${LDAP_ADMIN_DN}
objectClass: top
objectClass: organizationalRole
objectClass: simpleSecurityObject
cn: ${LDAP_ADMIN_USERNAME}
description: LDAP administrator
userPassword: ${LDAP_ADMIN_PASSWORD_HASH}

EOF
  fi

  if bool_true "${LDAP_CREATE_PEOPLE_OU}"; then
    cat >> "${tmp_ldif}" <<EOF
dn: ou=${LDAP_PEOPLE_OU},${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: ${LDAP_PEOPLE_OU}

EOF
  fi

  if bool_true "${LDAP_CREATE_GROUPS_OU}"; then
    cat >> "${tmp_ldif}" <<EOF
dn: ou=${LDAP_GROUPS_OU},${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: ${LDAP_GROUPS_OU}

EOF
  fi

  if bool_true "${LDAP_ENABLE_ACCESSLOG}"; then
    accesslog_attr="$(first_rdn_attr "${LDAP_ACCESSLOG_SUFFIX}")"
    accesslog_value="$(first_rdn_value "${LDAP_ACCESSLOG_SUFFIX}")"
    [ "${accesslog_attr}" = 'cn' ] || die "LDAP_ACCESSLOG_SUFFIX must begin with cn= when accesslog is enabled."
    cat >> "${tmp_ldif}" <<EOF
dn: ${LDAP_ACCESSLOG_SUFFIX}
objectClass: top
objectClass: auditContainer
cn: ${accesslog_value}

EOF
  fi

  printf '%s' "${tmp_ldif}"
}

should_initialize() {
  if [ -f "${LDAP_DB_DIR}/.docker-openldap-initialized" ]; then
    return 1
  fi

  if find "${LDAP_DB_DIR}" -mindepth 1 -maxdepth 1 -not -name '.docker-openldap-initialized' | read -r _; then
    return 1
  fi

  if bool_true "${LDAP_ENABLE_ACCESSLOG}"; then
    if find "${LDAP_ACCESSLOG_DB_DIR}" -mindepth 1 -maxdepth 1 | read -r _; then
      return 1
    fi
  fi

  return 0
}

start_temp_slapd() {
  rm -f "${LDAP_RUN_DIR}/slapd.pid" "${LDAP_RUN_DIR}/slapd.args"

  if config_backend_is_slapd_d; then
    su-exec ldap:ldap slapd -F "${LDAP_CONFIG_DIR}" -h "${LDAP_LDAPI_URI}" -d 0 &
  else
    su-exec ldap:ldap slapd -f "${LDAP_CONF}" -h "${LDAP_LDAPI_URI}" -d 0 &
  fi
  TEMP_SLAPD_PID="$!"

  i=0
  while [ "$i" -lt 30 ]; do
    if ldapwhoami -Q -Y EXTERNAL -H "${LDAP_LDAPI_URI}" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done

  kill "${TEMP_SLAPD_PID}" >/dev/null 2>&1 || true
  wait "${TEMP_SLAPD_PID}" >/dev/null 2>&1 || true
  die "Temporary slapd instance did not become ready."
}

stop_temp_slapd() {
  if [ -n "${TEMP_SLAPD_PID:-}" ]; then
    kill "${TEMP_SLAPD_PID}" >/dev/null 2>&1 || true
    wait "${TEMP_SLAPD_PID}" >/dev/null 2>&1 || true
    TEMP_SLAPD_PID=''
  fi
}

apply_ldif() {
  file="$1"
  mode="$(init_file_type "$file")"

  if [ "$mode" = 'modify' ]; then
    log "Applying LDIF via ldapmodify: $file"
    ldapmodify -x -D "${LDAP_ADMIN_DN}" -w "${LDAP_ADMIN_PASSWORD}" -H "${LDAP_LDAPI_URI}" -f "$file"
  else
    log "Applying LDIF via ldapadd: $file"
    ldapadd -x -D "${LDAP_ADMIN_DN}" -w "${LDAP_ADMIN_PASSWORD}" -H "${LDAP_LDAPI_URI}" -f "$file"
  fi
}

run_initdb_scripts() {
  if [ ! -d "${LDAP_INITDB_DIR}" ]; then
    return 0
  fi

  for file in "${LDAP_INITDB_DIR}"/*; do
    [ -e "$file" ] || continue
    case "$file" in
      *.sh)
        log "Running init script: $file"
        if [ -x "$file" ]; then
          "$file"
        else
          /bin/sh "$file"
        fi
        ;;
      *.ldif)
        apply_ldif "$file"
        ;;
      *)
        warn "Ignoring unsupported initdb file: $file"
        ;;
    esac
  done
}

validate_generated_config() {
  [ -f "${LDAP_CONF}" ] || die "slapd.conf not found: ${LDAP_CONF}"
  slaptest -u -f "${LDAP_CONF}" >/dev/null
}

dir_has_entries() {
  dir="$1"

  if [ ! -d "$dir" ]; then
    return 1
  fi

  if find "$dir" -mindepth 1 -maxdepth 1 | read -r _; then
    return 0
  fi

  return 1
}

config_backend_is_slapd_d() {
  [ "${LDAP_CONFIG_BACKEND}" = 'slapd.d' ]
}

validate_config_dir() {
  [ -d "${LDAP_CONFIG_DIR}" ] || die "slapd.d config directory not found: ${LDAP_CONFIG_DIR}"
  dir_has_entries "${LDAP_CONFIG_DIR}" || die "slapd.d config directory is empty: ${LDAP_CONFIG_DIR}"
  slaptest -u -F "${LDAP_CONFIG_DIR}" >/dev/null
}

materialize_config_backend() {
  ACTIVE_LDAP_CONFIG_BACKEND='slapd.conf'
  ACTIVE_LDAP_CONFIG_FRESH=0

  if ! config_backend_is_slapd_d; then
    validate_generated_config
    return 0
  fi

  if dir_has_entries "${LDAP_CONFIG_DIR}"; then
    ACTIVE_LDAP_CONFIG_BACKEND='slapd.d'
    log "Existing slapd.d configuration detected at ${LDAP_CONFIG_DIR}. Using persisted cn=config tree."
    warn "Persisted slapd.d is authoritative. Environment-based config changes, custom schema includes, and config snippets are ignored until ${LDAP_CONFIG_DIR} is removed."
    validate_config_dir
    return 0
  fi

  validate_generated_config

  tmp_dir="$(mktemp -d)"
  tmp_log="$(mktemp)"
  trap 'rm -rf "$tmp_dir"; rm -f "$tmp_log"' EXIT INT TERM

  if ! slaptest -f "${LDAP_CONF}" -F "${tmp_dir}" > /dev/null 2>"${tmp_log}"; then
    if dir_has_entries "${tmp_dir}" && slaptest -u -F "${tmp_dir}" >/dev/null 2>&1; then
      warn "slaptest returned non-zero while generating slapd.d, but the resulting cn=config tree validates and will be used."
      warn "This can happen on a fresh MDB backend before the database files exist yet."
    else
      cat "${tmp_log}" >&2 || true
      die "Failed to generate slapd.d from ${LDAP_CONF}"
    fi
  fi

  mkdir -p "${LDAP_CONFIG_DIR}"
  cp -a "${tmp_dir}"/. "${LDAP_CONFIG_DIR}"/
  chown -R ldap:ldap "${LDAP_CONFIG_DIR}"
  validate_config_dir
  rm -rf "${tmp_dir}"
  rm -f "${tmp_log}"
  trap - EXIT INT TERM

  ACTIVE_LDAP_CONFIG_BACKEND='slapd.d'
  ACTIVE_LDAP_CONFIG_FRESH=1

  log "Generated slapd.d configuration at ${LDAP_CONFIG_DIR} from ${LDAP_CONF}"
}

should_bootstrap_from_env() {
  if bool_true "${LDAP_SKIP_DEFAULT_CONFIG}"; then
    return 1
  fi

  if config_backend_is_slapd_d && [ "${ACTIVE_LDAP_CONFIG_FRESH:-0}" -ne 1 ]; then
    return 1
  fi

  return 0
}

normalize_env() {
  file_env LDAP_ADMIN_PASSWORD
  file_env LDAP_ADMIN_PASSWORD_HASH

  export LDAP_CONF="${LDAP_CONF:-/etc/openldap/slapd.conf}"
  export LDAP_RUN_DIR="${LDAP_RUN_DIR:-/var/run/openldap}"
  export LDAP_LDAPI_URI="${LDAP_LDAPI_URI:-ldapi://%2Fvar%2Frun%2Fopenldap%2Fldapi}"
  export LDAP_DB_DIR="${LDAP_DB_DIR:-/var/lib/openldap/openldap-data}"
  export LDAP_INITDB_DIR="${LDAP_INITDB_DIR:-/docker-entrypoint-initdb.d}"

  export LDAP_MODULE_PATH="${LDAP_MODULE_PATH:-/usr/lib/openldap/openldap}"
  export LDAP_SCHEMA_DIR="${LDAP_SCHEMA_DIR:-/etc/openldap/openldap/schema}"
  export LDAP_CUSTOM_SCHEMA_DIR="${LDAP_CUSTOM_SCHEMA_DIR:-/etc/openldap/custom-schema}"
  export LDAP_CUSTOM_PRECONFIG_DIR="${LDAP_CUSTOM_PRECONFIG_DIR:-/etc/openldap/custom-config/pre}"
  export LDAP_CUSTOM_POSTCONFIG_DIR="${LDAP_CUSTOM_POSTCONFIG_DIR:-/etc/openldap/custom-config/post}"
  export LDAP_CONFIG_BACKEND="${LDAP_CONFIG_BACKEND:-slapd.conf}"
  export LDAP_CONFIG_DIR="${LDAP_CONFIG_DIR:-/etc/openldap/slapd.d}"

  case "${LDAP_CONFIG_BACKEND}" in
    slapd.conf|slapd.d) ;;
    *) die "LDAP_CONFIG_BACKEND must be either slapd.conf or slapd.d. Current value: ${LDAP_CONFIG_BACKEND}" ;;
  esac

  export LDAP_SKIP_DEFAULT_CONFIG="${LDAP_SKIP_DEFAULT_CONFIG:-false}"
  export LDAP_ENABLE_TLS="${LDAP_ENABLE_TLS:-false}"
  export LDAP_ENABLE_LDAPS="${LDAP_ENABLE_LDAPS:-${LDAP_ENABLE_TLS}}"
  export LDAP_ENABLE_LDAP="${LDAP_ENABLE_LDAP:-true}"
  export LDAP_REQUIRE_TLS="${LDAP_REQUIRE_TLS:-false}"
  export LDAP_ALLOW_ANON_BIND="${LDAP_ALLOW_ANON_BIND:-true}"
  export LDAP_ENABLE_PEERCRED_ADMIN="${LDAP_ENABLE_PEERCRED_ADMIN:-true}"

  export LDAP_DOMAIN="${LDAP_DOMAIN:-}"
  export LDAP_BASE_DN="${LDAP_BASE_DN:-${LDAP_ROOT:-}}"
  if [ -z "${LDAP_BASE_DN}" ] && [ -n "${LDAP_DOMAIN}" ]; then
    LDAP_BASE_DN="$(domain_to_base_dn "${LDAP_DOMAIN}")"
    export LDAP_BASE_DN
  fi
  [ -n "${LDAP_BASE_DN}" ] || LDAP_BASE_DN='dc=example,dc=org'
  export LDAP_BASE_DN

  export LDAP_ORGANISATION="${LDAP_ORGANISATION:-$(default_org_from_dn "${LDAP_BASE_DN}")}"
  export LDAP_ADMIN_USERNAME="${LDAP_ADMIN_USERNAME:-admin}"
  export LDAP_ADMIN_DN="${LDAP_ADMIN_DN:-cn=${LDAP_ADMIN_USERNAME},${LDAP_BASE_DN}}"

  export LDAP_PASSWORD_HASH_SCHEME="${LDAP_PASSWORD_HASH_SCHEME:-{SSHA}}"

  if [ -z "${LDAP_ADMIN_PASSWORD_HASH}" ]; then
    [ -n "${LDAP_ADMIN_PASSWORD}" ] || die "LDAP_ADMIN_PASSWORD or LDAP_ADMIN_PASSWORD_HASH is required."
    LDAP_ADMIN_PASSWORD_HASH="$(slappasswd -h "${LDAP_PASSWORD_HASH_SCHEME}" -s "${LDAP_ADMIN_PASSWORD}")"
    export LDAP_ADMIN_PASSWORD_HASH
  fi

  export LDAP_PORT_NUMBER="${LDAP_PORT_NUMBER:-${LDAP_PORT:-389}}"
  export LDAP_LDAPS_PORT_NUMBER="${LDAP_LDAPS_PORT_NUMBER:-${LDAP_LDAPS_PORT:-636}}"

  export LDAP_LOG_LEVEL="${LDAP_LOG_LEVEL:-256}"
  export LDAP_DEBUG_LEVEL="${LDAP_DEBUG_LEVEL:-${LDAP_LOG_LEVEL}}"
  case "${LDAP_DEBUG_LEVEL}" in
    ''|*[!0-9]*) LDAP_DEBUG_LEVEL=0 ;;
  esac
  export LDAP_DEBUG_LEVEL

  export LDAP_THREADS="${LDAP_THREADS:-}"
  export LDAP_TIMELIMIT="${LDAP_TIMELIMIT:-}"
  export LDAP_SIZELIMIT="${LDAP_SIZELIMIT:-}"

  export LDAP_MDB_MAXSIZE="${LDAP_MDB_MAXSIZE:-1073741824}"
  export LDAP_MDB_CHECKPOINT="${LDAP_MDB_CHECKPOINT:-1024 5}"
  export LDAP_MDB_DBNOSYNC="${LDAP_MDB_DBNOSYNC:-false}"

  export LDAP_CREATE_ADMIN_ENTRY="${LDAP_CREATE_ADMIN_ENTRY:-true}"
  export LDAP_SKIP_DEFAULT_TREE="${LDAP_SKIP_DEFAULT_TREE:-false}"
  export LDAP_CREATE_PEOPLE_OU="${LDAP_CREATE_PEOPLE_OU:-true}"
  export LDAP_CREATE_GROUPS_OU="${LDAP_CREATE_GROUPS_OU:-true}"
  export LDAP_PEOPLE_OU="${LDAP_PEOPLE_OU:-people}"
  export LDAP_GROUPS_OU="${LDAP_GROUPS_OU:-groups}"

  export LDAP_EXTRA_SCHEMAS="${LDAP_EXTRA_SCHEMAS:-cosine inetorgperson nis}"
  export LDAP_LOAD_MODULES="${LDAP_LOAD_MODULES:-}"

  export LDAP_ENABLE_MONITOR_DB="${LDAP_ENABLE_MONITOR_DB:-true}"
  export LDAP_ENABLE_SYNCPROV="${LDAP_ENABLE_SYNCPROV:-false}"
  export LDAP_SYNCPROV_CHECKPOINT="${LDAP_SYNCPROV_CHECKPOINT:-100 10}"
  export LDAP_SYNCPROV_SESSIONLOG="${LDAP_SYNCPROV_SESSIONLOG:-}"

  export LDAP_ENABLE_MEMBEROF="${LDAP_ENABLE_MEMBEROF:-false}"
  export LDAP_ENABLE_REFINT="${LDAP_ENABLE_REFINT:-${LDAP_ENABLE_MEMBEROF}}"

  export LDAP_ENABLE_ACCESSLOG="${LDAP_ENABLE_ACCESSLOG:-false}"
  export LDAP_ACCESSLOG_SUFFIX="${LDAP_ACCESSLOG_SUFFIX:-cn=accesslog}"
  export LDAP_ACCESSLOG_ROOTDN="${LDAP_ACCESSLOG_ROOTDN:-cn=accesslog}"
  export LDAP_ACCESSLOG_DB_DIR="${LDAP_ACCESSLOG_DB_DIR:-/var/lib/openldap/accesslog}"
  export LDAP_ACCESSLOG_MAXSIZE="${LDAP_ACCESSLOG_MAXSIZE:-268435456}"
  export LDAP_ACCESSLOG_LOGOPS="${LDAP_ACCESSLOG_LOGOPS:-writes}"
  export LDAP_ACCESSLOG_LOGPURGE="${LDAP_ACCESSLOG_LOGPURGE:-07+00:00 01+00:00}"

  export LDAP_TLS_CERT_FILE="${LDAP_TLS_CERT_FILE:-}"
  export LDAP_TLS_KEY_FILE="${LDAP_TLS_KEY_FILE:-}"
  export LDAP_TLS_CA_FILE="${LDAP_TLS_CA_FILE:-}"
  export LDAP_TLS_DH_PARAM_FILE="${LDAP_TLS_DH_PARAM_FILE:-}"
  export LDAP_TLS_CIPHER_SUITE="${LDAP_TLS_CIPHER_SUITE:-}"
  export LDAP_TLS_VERIFY_CLIENT="${LDAP_TLS_VERIFY_CLIENT:-never}"
  export LDAP_SIMPLE_BIND_MIN_SSF="${LDAP_SIMPLE_BIND_MIN_SSF:-128}"

  if ! bool_true "${LDAP_ENABLE_LDAP}" && ! bool_true "${LDAP_ENABLE_LDAPS}"; then
    die "At least one of LDAP_ENABLE_LDAP or LDAP_ENABLE_LDAPS must be true."
  fi

  if bool_true "${LDAP_REQUIRE_TLS}" && ! bool_true "${LDAP_ENABLE_TLS}"; then
    die "LDAP_REQUIRE_TLS=true requires LDAP_ENABLE_TLS=true."
  fi
}

build_listen_uris() {
  if [ -n "${LDAP_LISTEN_URIS:-}" ]; then
    printf '%s' "${LDAP_LISTEN_URIS}"
    return 0
  fi

  uris="${LDAP_LDAPI_URI}"
  if bool_true "${LDAP_ENABLE_LDAP}"; then
    uris="${uris} ldap://0.0.0.0:${LDAP_PORT_NUMBER}"
  fi
  if bool_true "${LDAP_ENABLE_LDAPS}"; then
    uris="${uris} ldaps://0.0.0.0:${LDAP_LDAPS_PORT_NUMBER}"
  fi

  printf '%s' "${uris}"
}

prepare_fs() {
  ensure_dir "${LDAP_DB_DIR}" ldap ldap 0700
  ensure_dir "${LDAP_RUN_DIR}" ldap ldap 0755
  ensure_dir "${LDAP_ACCESSLOG_DB_DIR}" ldap ldap 0700
  mkdir -p "${LDAP_CUSTOM_SCHEMA_DIR}" "${LDAP_CUSTOM_PRECONFIG_DIR}" "${LDAP_CUSTOM_POSTCONFIG_DIR}" "${LDAP_INITDB_DIR}" "${LDAP_CONFIG_DIR}"
}

main() {
  if [ "${1:-slapd}" != 'slapd' ]; then
    exec "$@"
  fi
  shift || true

  normalize_env
  prepare_fs

  if config_backend_is_slapd_d && dir_has_entries "${LDAP_CONFIG_DIR}"; then
    log "slapd.d backend selected with existing configuration at ${LDAP_CONFIG_DIR}"
  elif bool_true "${LDAP_SKIP_DEFAULT_CONFIG}"; then
    log "Using mounted/custom slapd.conf at ${LDAP_CONF}"
  else
    write_config
  fi

  materialize_config_backend

  if should_initialize; then
    if should_bootstrap_from_env; then
    if { ! bool_true "${LDAP_SKIP_DEFAULT_TREE}"; } || initdb_has_entries; then
      [ -n "${LDAP_ADMIN_PASSWORD:-}" ] || die "Automatic first-start bootstrap requires LDAP_ADMIN_PASSWORD or LDAP_ADMIN_PASSWORD_FILE. LDAP_ADMIN_PASSWORD_HASH alone is not sufficient for LDAP-based initialization."
    fi
    log "Fresh database detected. Bootstrapping initial directory data."
    start_temp_slapd
    if ! bool_true "${LDAP_SKIP_DEFAULT_TREE}"; then
      base_ldif="$(bootstrap_base_ldif)"
      apply_ldif "${base_ldif}"
      rm -f "${base_ldif}"
    fi
    run_initdb_scripts
    stop_temp_slapd
    touch "${LDAP_DB_DIR}/.docker-openldap-initialized"
    chown ldap:ldap "${LDAP_DB_DIR}/.docker-openldap-initialized"
    elif config_backend_is_slapd_d; then
      log "Fresh data directory detected with persisted slapd.d configuration. Skipping automatic bootstrap."
      warn "Persisted cn=config may have diverged from current environment values. Initialize directory data manually, or remove ${LDAP_CONFIG_DIR} to reseed slapd.d from ${LDAP_CONF}."
    else
      log "Fresh database detected, but automatic bootstrap is disabled when LDAP_SKIP_DEFAULT_CONFIG=true."
    fi
  else
    log "Existing database detected. Skipping first-start bootstrap."
  fi

  rm -f "${LDAP_RUN_DIR}/slapd.pid" "${LDAP_RUN_DIR}/slapd.args"
  LISTEN_URIS="$(build_listen_uris)"
  log "Starting slapd with config backend ${ACTIVE_LDAP_CONFIG_BACKEND} and URIs: ${LISTEN_URIS}"
  if config_backend_is_slapd_d; then
    exec su-exec ldap:ldap slapd -F "${LDAP_CONFIG_DIR}" -h "${LISTEN_URIS}" -d "${LDAP_DEBUG_LEVEL}" "$@"
  fi
  exec su-exec ldap:ldap slapd -f "${LDAP_CONF}" -h "${LISTEN_URIS}" -d "${LDAP_DEBUG_LEVEL}" "$@"
}

main "$@"
