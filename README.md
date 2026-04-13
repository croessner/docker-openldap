# OpenLDAP on Alpine

[![Publish Docker Image](https://github.com/croessner/docker-openldap/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/croessner/docker-openldap/actions/workflows/docker-publish.yml)
[![License: MIT](https://img.shields.io/github/license/croessner/docker-openldap)](./LICENSE)
[![Last Commit](https://img.shields.io/github/last-commit/croessner/docker-openldap)](https://github.com/croessner/docker-openldap/commits/main)
[![Stars](https://img.shields.io/github/stars/croessner/docker-openldap?style=social)](https://github.com/croessner/docker-openldap/stargazers)

This project builds a complete OpenLDAP image on **Alpine Linux**, compiles **a pinned OpenLDAP version directly from source**, and includes **dynamic backends, overlays, and password modules** directly in the image. By default, the container seeds and starts from a generated **`slapd.conf`**, but it can also switch to a persistent **`slapd.d` / `cn=config`** runtime mode. The configuration follows the style of well-known container images: as much as practical via **environment variables**, everything else via **LDIF bootstrap**, **schema directories**, and **config snippets**.

## Table of Contents

- [Goals](#goals)
- [Project Structure](#project-structure)
- [Included Components](#included-components)
- [Quick Start](#quick-start)
- [Publishing](#publishing)
- [License](#license)
- [Operating Model](#operating-model)
- [Important Volumes / Mountpoints](#important-volumes--mountpoints)
- [Environment Variables](#environment-variables)
- [Enabling TLS](#enabling-tls)
- [Init Scripts and LDIFs](#init-scripts-and-ldifs)
- [Custom Schemas](#custom-schemas)
- [Custom Config Snippets](#custom-config-snippets)
- [Fully Custom `slapd.conf`](#fully-custom-slapdconf)
- [One-Shot `slapd.d` Mode](#one-shot-slapdd-mode)
- [Health Check](#health-check)
- [Notes and Limitations](#notes-and-limitations)
- [Development / Convenience](#development--convenience)
- [References](#references)

## Goals

- Alpine-based runtime
- Pinned OpenLDAP source version via Docker build args
- Env-driven default configuration with optional persistent `slapd.d` / `cn=config`
- Complete image including compiled backends, overlays, and password modules
- Solid defaults for `mdb`
- First-time initialization via `docker-entrypoint-initdb.d`
- TLS, accesslog, syncprov, memberOf/refint can be enabled via env vars
- Extensible through custom `.schema` files and `.conf` snippets
- Clean container logs via `stdout/stderr`
- Health check via local `ldapi`

## Project Structure

```text
.
├── Dockerfile
├── docker-entrypoint.sh
├── docker-healthcheck.sh
├── README.md
├── .env.example
├── .gitignore
├── Makefile
└── examples
    ├── docker-compose.yml
    ├── bootstrap
    │   └── 20-demo-user.ldif
    └── custom-config
        ├── post
        │   └── 70-extra.conf
        └── pre
            └── 50-global.conf
```

## Included Components

The image is built in two stages:

- A **builder stage** compiles OpenLDAP from the official source tarball
- A **runtime stage** keeps Alpine as the base image and only adds the required runtime libraries plus `su-exec`

The OpenLDAP build enables dynamic modules so the image can load not only `mdb`, but also additional backends and overlays from the upstream source tree. The **generated default configuration** intentionally focuses on **a clean `mdb` setup**. For special cases, you can load additional modules, provide your own `slapd.conf`, or persist `slapd.d` as the runtime source of truth.

## Quick Start

### 1. Build

```bash
docker build -t openldap-alpine-slapdconf .
```

To pin a specific upstream release explicitly:

```bash
docker build \
  --build-arg OPENLDAP_VERSION=2.6.13 \
  --build-arg OPENLDAP_SHA256=d693b49517a42efb85a1a364a310aed16a53d428d1b46c0d31ef3fba78fcb656 \
  -t openldap-alpine-slapdconf:2.6.13 .
```

Multi-arch build with `buildx`:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg OPENLDAP_VERSION=2.6.13 \
  --build-arg OPENLDAP_SHA256=d693b49517a42efb85a1a364a310aed16a53d428d1b46c0d31ef3fba78fcb656 \
  -t openldap-alpine-slapdconf:2.6.13 \
  .
```

Publish to Docker Hub:

```bash
docker login
make push IMAGE_NAME=chrroessner/openldap TAG=latest
```

Create a local SBOM export:

```bash
make sbom-local
```

### 2. Start the container

```bash
docker run -d \
  --name openldap \
  -p 389:389 \
  -p 636:636 \
  -e LDAP_DOMAIN=example.org \
  -e LDAP_BASE_DN=dc=example,dc=org \
  -e LDAP_ORGANISATION="Example Inc." \
  -e LDAP_ADMIN_PASSWORD=supersecret \
  -v $(pwd)/data/openldap:/var/lib/openldap/openldap-data \
  -v $(pwd)/data/accesslog:/var/lib/openldap/accesslog \
  -v $(pwd)/examples/bootstrap:/docker-entrypoint-initdb.d:ro \
  openldap-alpine-slapdconf
```

### 3. Test

```bash
ldapsearch -x -H ldap://127.0.0.1:389 -b dc=example,dc=org -D "cn=admin,dc=example,dc=org" -w supersecret
```

## Publishing

This repository includes a GitHub Actions workflow at `.github/workflows/docker-publish.yml` that publishes a multi-arch image to Docker Hub as `chrroessner/openldap`.

The workflow runs:

- on pushes to `main`
- on pushes to `master`
- on Git tags matching `v*`
- every Monday via `schedule`
- manually via `workflow_dispatch`

The scheduled run uses `docker/build-push-action` with `pull: true`. That means a rebuild will automatically pick up a newer digest for the pinned Alpine minor tag in the Dockerfile, for example `alpine:3.23`.

SBOM is integrated in three places:

- the published image gets OCI attestations for both provenance and SBOM
- the workflow exports downloadable SPDX JSON files for `linux/amd64` and `linux/arm64`
- the Dockerfile enables BuildKit SBOM scanning for both the build context and the builder stage, so the SBOM is not limited to the final runtime layer

Required GitHub repository secrets:

- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`

Recommended Docker Hub setup:

- create the public repository `chrroessner/openldap`
- create a Docker Hub access token dedicated to CI
- keep `latest` for the default branch
- publish release tags in the form `v<openldap-version>-r<revision>`, for example `v2.6.13-r1`

Important limitation:

- this does not automatically jump from Alpine `3.23` to `3.24`
- for a new Alpine minor release, update `ALPINE_VERSION` in `Dockerfile`

Local SBOM usage:

```bash
make sbom-local
ls dist/sbom-local | grep sbom
```

Registry SBOM inspection after push:

```bash
make sbom-registry IMAGE_NAME=chrroessner/openldap TAG=latest
```

Suggested first publish:

```bash
git tag v2.6.13-r1
git push origin main --tags
```

## License

The repository content is licensed under the MIT License. See [LICENSE](./LICENSE).

The published container image additionally includes OpenLDAP, which is distributed under `OLDAP-2.8`. Because of that, the OCI image metadata declares `MIT AND OLDAP-2.8`.

## Operating Model

On startup, the following happens:

1. The entrypoint script reads and normalizes the environment variables.
2. If `LDAP_CONFIG_BACKEND=slapd.conf`, it validates and starts from `slapd.conf`.
3. If `LDAP_CONFIG_BACKEND=slapd.d`, the container behaves in one of two modes:
   - If `LDAP_CONFIG_DIR` is empty, it seeds `slapd.d` once from `slapd.conf` using `slaptest -f ... -F ...`
   - If `LDAP_CONFIG_DIR` already contains data, the persisted `slapd.d` tree is treated as authoritative
4. If the data directory is empty and the active configuration was seeded from the current env-driven `slapd.conf`, a fresh directory is initialized:
   - Base entry for `LDAP_BASE_DN`
   - Optional admin entry
   - Optional `people` and `groups` OUs
   - Optional accesslog base entry
   - Followed by processing `docker-entrypoint-initdb.d`
5. If a persisted `slapd.d` tree is reused, env-driven bootstrap is skipped intentionally because the live `cn=config` tree may already differ from the current environment values.
6. After that, `slapd` starts in the foreground and logs to the container output.

## Important Volumes / Mountpoints

| Path in Container | Purpose |
|---|---|
| `/var/lib/openldap/openldap-data` | Primary `mdb` database |
| `/var/lib/openldap/accesslog` | Separate accesslog DB |
| `/docker-entrypoint-initdb.d` | First-time initialization (`.ldif`, `.sh`) |
| `/etc/openldap/custom-schema` | Additional `.schema` files |
| `/etc/openldap/custom-config/pre` | Additional global config before DB blocks |
| `/etc/openldap/custom-config/post` | Additional config after the generated DB blocks |
| `/etc/openldap/certs` | Certificates/keys for TLS |

## Environment Variables

### Core Parameters

| Variable | Default | Meaning |
|---|---:|---|
| `LDAP_DOMAIN` | empty | DNS domain as convenience input |
| `LDAP_BASE_DN` | `dc=example,dc=org` | Base DN / suffix |
| `LDAP_ORGANISATION` | derived from base DN | Value for the base entry |
| `LDAP_ADMIN_USERNAME` | `admin` | CN of the default admin |
| `LDAP_ADMIN_PASSWORD` | – | Admin password in plain text |
| `LDAP_ADMIN_PASSWORD_FILE` | – | Password from file/secret |
| `LDAP_ADMIN_PASSWORD_HASH` | – | Pre-hashed alternative to `LDAP_ADMIN_PASSWORD` for runtime authentication; first-start LDAP bootstrap still needs the plain password |
| `LDAP_ADMIN_DN` | `cn=<admin>,<baseDN>` | Full DN of the admin |

### Listener / Runtime

| Variable | Default | Meaning |
|---|---:|---|
| `LDAP_ENABLE_LDAP` | `true` | Enable LDAP on port 389 |
| `LDAP_ENABLE_LDAPS` | same as `LDAP_ENABLE_TLS` | Enable LDAPS on port 636 |
| `LDAP_PORT_NUMBER` | `389` | LDAP port |
| `LDAP_LDAPS_PORT_NUMBER` | `636` | LDAPS port |
| `LDAP_LDAPI_URI` | `ldapi://%2Fvar%2Frun%2Fopenldap%2Fldapi` | Local IPC socket used for health checks and bootstrap |
| `LDAP_LOG_LEVEL` | `256` | `slapd.conf` `loglevel` |
| `LDAP_DEBUG_LEVEL` | same as `LDAP_LOG_LEVEL` | Numeric `slapd -d` value |
| `LDAP_THREADS` | empty | Optional thread tuning |
| `LDAP_TIMELIMIT` | empty | Optional global search limit |
| `LDAP_SIZELIMIT` | empty | Optional global size limit |

### Database / Bootstrap

| Variable | Default | Meaning |
|---|---:|---|
| `LDAP_DB_DIR` | `/var/lib/openldap/openldap-data` | Data path of the main DB |
| `LDAP_MDB_MAXSIZE` | `1073741824` | `mdb maxsize` |
| `LDAP_MDB_CHECKPOINT` | `1024 5` | `checkpoint` for `mdb` |
| `LDAP_MDB_DBNOSYNC` | `false` | Optional `dbnosync` |
| `LDAP_SKIP_DEFAULT_TREE` | `false` | Do not create the base tree automatically |
| `LDAP_CREATE_ADMIN_ENTRY` | `true` | Also create a real admin entry |
| `LDAP_CREATE_PEOPLE_OU` | `true` | Create `ou=people` |
| `LDAP_CREATE_GROUPS_OU` | `true` | Create `ou=groups` |
| `LDAP_PEOPLE_OU` | `people` | Name of the user OU |
| `LDAP_GROUPS_OU` | `groups` | Name of the group OU |
| `LDAP_INITDB_DIR` | `/docker-entrypoint-initdb.d` | Init directory |

### Schemas / Modules / Extension

| Variable | Default | Meaning |
|---|---:|---|
| `LDAP_CONFIG_BACKEND` | `slapd.conf` | Runtime config backend: `slapd.conf` or `slapd.d` |
| `LDAP_CONFIG_DIR` | `/etc/openldap/slapd.d` | Persistent `slapd.d` directory |
| `LDAP_EXTRA_SCHEMAS` | `cosine inetorgperson nis` | Additional standard schemas |
| `LDAP_LOAD_MODULES` | empty | Additional modules, comma- or space-separated |
| `LDAP_CUSTOM_SCHEMA_DIR` | `/etc/openldap/custom-schema` | Custom `.schema` files |
| `LDAP_CUSTOM_PRECONFIG_DIR` | `/etc/openldap/custom-config/pre` | Additional global config |
| `LDAP_CUSTOM_POSTCONFIG_DIR` | `/etc/openldap/custom-config/post` | Additional DB/overlay config |
| `LDAP_SKIP_DEFAULT_CONFIG` | `false` | Use your own complete `slapd.conf` |

### TLS

| Variable | Default | Meaning |
|---|---:|---|
| `LDAP_ENABLE_TLS` | `false` | Enable TLS directives in `slapd.conf` |
| `LDAP_REQUIRE_TLS` | `false` | Block unencrypted simple binds |
| `LDAP_TLS_CERT_FILE` | empty | Server certificate |
| `LDAP_TLS_KEY_FILE` | empty | Private key |
| `LDAP_TLS_CA_FILE` | empty | CA file |
| `LDAP_TLS_DH_PARAM_FILE` | empty | Optional DH parameters |
| `LDAP_TLS_CIPHER_SUITE` | empty | Optional cipher suite |
| `LDAP_TLS_VERIFY_CLIENT` | `never` | `TLSVerifyClient` |
| `LDAP_SIMPLE_BIND_MIN_SSF` | `128` | Minimum SSF when `LDAP_REQUIRE_TLS=true` |

### Overlays / Extra Features

| Variable | Default | Meaning |
|---|---:|---|
| `LDAP_ENABLE_MONITOR_DB` | `true` | Add `database monitor` |
| `LDAP_ENABLE_SYNCPROV` | `false` | Enable `overlay syncprov` |
| `LDAP_SYNCPROV_CHECKPOINT` | `100 10` | `syncprov-checkpoint` |
| `LDAP_SYNCPROV_SESSIONLOG` | empty | Optional `syncprov-sessionlog` |
| `LDAP_ENABLE_MEMBEROF` | `false` | Enable `memberOf` overlay |
| `LDAP_ENABLE_REFINT` | same as `LDAP_ENABLE_MEMBEROF` | Enable `refint` overlay |
| `LDAP_ENABLE_ACCESSLOG` | `false` | Enable accesslog DB + overlay |
| `LDAP_ACCESSLOG_SUFFIX` | `cn=accesslog` | Suffix of the accesslog DB |
| `LDAP_ACCESSLOG_ROOTDN` | `cn=accesslog` | RootDN of the accesslog DB |
| `LDAP_ACCESSLOG_DB_DIR` | `/var/lib/openldap/accesslog` | Path of the accesslog DB |
| `LDAP_ACCESSLOG_MAXSIZE` | `268435456` | `mdb maxsize` for accesslog |
| `LDAP_ACCESSLOG_LOGOPS` | `writes` | `logops` |
| `LDAP_ACCESSLOG_LOGPURGE` | `07+00:00 01+00:00` | `logpurge` |

## Enabling TLS

Example:

```bash
docker run -d \
  --name openldap \
  -p 389:389 \
  -p 636:636 \
  -e LDAP_DOMAIN=example.org \
  -e LDAP_BASE_DN=dc=example,dc=org \
  -e LDAP_ADMIN_PASSWORD=supersecret \
  -e LDAP_ENABLE_TLS=true \
  -e LDAP_ENABLE_LDAPS=true \
  -e LDAP_REQUIRE_TLS=true \
  -e LDAP_TLS_CERT_FILE=/etc/openldap/certs/tls.crt \
  -e LDAP_TLS_KEY_FILE=/etc/openldap/certs/tls.key \
  -e LDAP_TLS_CA_FILE=/etc/openldap/certs/ca.crt \
  -v $(pwd)/certs:/etc/openldap/certs:ro \
  openldap-alpine-slapdconf
```

## Init Scripts and LDIFs

The `/docker-entrypoint-initdb.d` directory is processed **only when initializing an empty database for the first time**.

Supported file types:

- `*.ldif`
  - with `changetype:` -> `ldapmodify`
  - without `changetype:` -> `ldapadd`
- `*.sh`
  - executable or run via `/bin/sh`

All LDIFs are applied **locally via `ldapi:///` and SASL EXTERNAL**. The entrypoint script maps the local container root user to the configured `LDAP_ADMIN_DN`, so no plaintext credentials are required during the bootstrap phase.

Example file: `examples/bootstrap/20-demo-user.ldif`

## Custom Schemas

Place `.schema` files in:

```text
/etc/openldap/custom-schema
```

These files are automatically included via `include`.

## Custom Config Snippets

**Before** the database blocks:

```text
/etc/openldap/custom-config/pre
```

**After** the generated database blocks:

```text
/etc/openldap/custom-config/post
```

This allows you to add, for example:

- Global `security`, `limits`, `threads`
- Additional databases
- More overlays
- Fine-grained ACL adjustments
- Experimental or rare modules

## Fully Custom `slapd.conf`

If you want to bypass the default generation completely:

1. Mount your own `slapd.conf`
2. Set `LDAP_SKIP_DEFAULT_CONFIG=true`

Example:

```bash
docker run -d \
  --name openldap \
  -e LDAP_SKIP_DEFAULT_CONFIG=true \
  -v $(pwd)/my-slapd.conf:/etc/openldap/slapd.conf:ro \
  -v $(pwd)/data:/var/lib/openldap/openldap-data \
  openldap-alpine-slapdconf
```

In this mode, you are fully responsible for the configuration.

## One-Shot `slapd.d` Mode

If you prefer `cn=config` / `slapd.d` at runtime:

```bash
docker run -d \
  --name openldap \
  -e LDAP_CONFIG_BACKEND=slapd.d \
  -v $(pwd)/slapd.d:/etc/openldap/slapd.d \
  -v $(pwd)/data:/var/lib/openldap/openldap-data \
  openldap-alpine-slapdconf
```

Behavior in this mode:

- On the first start, an empty `LDAP_CONFIG_DIR` is seeded from the current `slapd.conf`
- On later starts, if `LDAP_CONFIG_DIR` already contains data, the persisted `slapd.d` tree is used as-is
- After `slapd.d` exists, environment-based config changes are no longer reapplied automatically
- This is intentional: the persisted `cn=config` tree becomes the source of truth

## Health Check

The health check runs against:

```text
ldapi://%2Fvar%2Frun%2Fopenldap%2Fldapi
```

It uses:

```bash
ldapsearch -Q -Y EXTERNAL -H ldapi://%2Fvar%2Frun%2Fopenldap%2Fldapi -LLL -s base -b "" namingContexts
```

This means container health does not depend on externally reachable ports or admin credentials.

## Notes and Limitations

- The default env-driven bootstrap path seeds from `slapd.conf`, but both `slapd.conf` and persistent `slapd.d` runtime modes are supported.
- OpenLDAP is **built from source in the builder stage**; Alpine provides the runtime base image and shared runtime libraries.
- The **default generation is tailored to `mdb`**. Other backends are available in the image, but should be configured through your own snippets or a custom `slapd.conf`.
- With `LDAP_CONFIG_BACKEND=slapd.d`, a populated `LDAP_CONFIG_DIR` becomes authoritative. Environment-based config changes are then seed-only and are no longer reapplied automatically.
- Automatic bootstrap of base entries and init LDIFs is performed only when the active runtime config was seeded from the current env-driven `slapd.conf`.
- Automatic LDAP-based bootstrap requires `LDAP_ADMIN_PASSWORD` or `LDAP_ADMIN_PASSWORD_FILE`. `LDAP_ADMIN_PASSWORD_HASH` alone is sufficient for runtime auth, but not for first-start init operations.
- `LDAP_DEBUG_LEVEL` should be set to a **numeric** value because it is passed directly to `slapd -d`.
- For production TLS operation, the certificate and key must be **readable by the `ldap` user**.
- Init LDIFs run only on **fresh** data directories.

## Development / Convenience

Build:

```bash
make build
```

Start via Compose:

```bash
make compose-up
```

Stop:

```bash
make compose-down
```

## References

- OpenLDAP Admin Guide: <https://www.openldap.org/doc/admin26/>
- OpenLDAP Downloads: <https://www.openldap.org/software/download/OpenLDAP/>
- Alpine Wiki OpenLDAP: <https://wiki.alpinelinux.org/wiki/Configure_OpenLDAP>
