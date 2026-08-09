# syntax=docker/dockerfile:1.7
ARG BUILDKIT_SBOM_SCAN_CONTEXT=true
ARG BUILDKIT_SBOM_SCAN_STAGE=true

ARG ALPINE_VERSION=3.24.1
ARG ALPINE_DIGEST=sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
ARG OPENLDAP_CHANNEL=lts
ARG OPENLDAP_VERSION=2.6.14
ARG OPENLDAP_SHA256=806dcd21d366428187fba3278da773d5930f774852c9e92517f950d585f19107
ARG IMAGE_REVISION=1
ARG OCI_SOURCE="https://github.com/croessner/docker-openldap"
ARG OCI_URL="https://hub.docker.com/r/chrroessner/openldap"
ARG OCI_DOCUMENTATION="https://github.com/croessner/docker-openldap#readme"
ARG OCI_VENDOR="Rößner-Network-Solutions"
ARG OCI_AUTHORS="Christian Rößner <christian@roessner.email>"
ARG OCI_LICENSES="MIT AND OLDAP-2.8"
ARG OCI_VERSION="dev"
ARG OCI_REVISION="unknown"

FROM --platform=$TARGETPLATFORM alpine:${ALPINE_VERSION}@${ALPINE_DIGEST} AS builder

ARG OPENLDAP_VERSION
ARG OPENLDAP_SHA256

LABEL org.opencontainers.image.title="OpenLDAP Alpine" \
      org.opencontainers.image.description="OpenLDAP built from pinned source on Alpine Linux with env-driven bootstrap and optional persistent slapd.d support" \
      org.opencontainers.image.licenses="OLDAP-2.8"

RUN apk upgrade --no-cache \
    && apk add --no-cache \
        argon2-dev \
        build-base \
        ca-certificates \
        curl \
        cyrus-sasl-dev \
        groff \
        libltdl \
        libtool \
        openssl-dev \
        tar \
        util-linux-dev \
    && case "${OPENLDAP_VERSION}" in \
         2.6.*) apk add --no-cache unixodbc-dev ;; \
       esac

WORKDIR /tmp/build

RUN curl -fsSLo openldap.tgz "https://www.openldap.org/software/download/OpenLDAP/openldap-release/openldap-${OPENLDAP_VERSION}.tgz" \
    && if [ -n "${OPENLDAP_SHA256}" ]; then \
         echo "${OPENLDAP_SHA256}  openldap.tgz" | sha256sum -c -; \
       fi \
    && tar -xzf openldap.tgz \
    && mv "openldap-${OPENLDAP_VERSION}" src

WORKDIR /tmp/build/src

RUN set -- \
        --prefix=/usr \
        --sbindir=/usr/sbin \
        --sysconfdir=/etc/openldap \
        --libexecdir=/usr/lib/openldap \
        --localstatedir=/var/lib/openldap \
        --enable-slapd \
        --enable-modules \
        --enable-backends=mod \
        --enable-overlays=mod \
        --enable-argon2 \
        --with-tls=openssl \
        --with-cyrus-sasl \
        --enable-syslog \
        --disable-wt \
    && case "${OPENLDAP_VERSION}" in \
         2.6.*) set -- "$@" --enable-sql=mod --disable-perl ;; \
       esac \
    && ./configure "$@" \
    && make depend \
    && make -j"$(getconf _NPROCESSORS_ONLN)" \
    && DESTDIR=/tmp/out make install \
    && make -C contrib/slapd-modules/passwd/sha2 \
         DESTDIR=/tmp/out \
         moduledir=/usr/lib/openldap/openldap \
         install \
    && schema_dest="/tmp/out/etc/openldap/openldap/schema" \
    && find /tmp/build/src \
         \( -path '/tmp/build/src/contrib/*' -o -path '/tmp/build/src/servers/slapd/*' \) \
         -type f \
         \( -name '*.schema' -o -name '*.ldif' \) \
         ! -path '*/tests/*' \
         ! -path '/tmp/build/src/servers/slapd/schema/*' \
         ! -path '/tmp/build/src/servers/slapd/slapd.ldif' \
         -exec cp {} "${schema_dest}/" \;

FROM --platform=$TARGETPLATFORM alpine:${ALPINE_VERSION}@${ALPINE_DIGEST}

ARG ALPINE_VERSION
ARG ALPINE_DIGEST
ARG OPENLDAP_VERSION
ARG OPENLDAP_CHANNEL
ARG IMAGE_REVISION
ARG OCI_SOURCE
ARG OCI_URL
ARG OCI_DOCUMENTATION
ARG OCI_VENDOR
ARG OCI_AUTHORS
ARG OCI_LICENSES
ARG OCI_VERSION
ARG OCI_REVISION

LABEL maintainer="Christian Rößner <christian@roessner.email>" \
      org.opencontainers.image.title="OpenLDAP Alpine" \
      org.opencontainers.image.description="OpenLDAP built from pinned source on Alpine Linux with env-driven bootstrap and optional persistent slapd.d support" \
      org.opencontainers.image.licenses="${OCI_LICENSES}" \
      org.opencontainers.image.vendor="${OCI_VENDOR}" \
      org.opencontainers.image.authors="${OCI_AUTHORS}" \
      org.opencontainers.image.source="${OCI_SOURCE}" \
      org.opencontainers.image.url="${OCI_URL}" \
      org.opencontainers.image.documentation="${OCI_DOCUMENTATION}" \
      org.opencontainers.image.version="${OCI_VERSION}" \
      org.opencontainers.image.revision="${OCI_REVISION}" \
      org.opencontainers.image.base.name="docker.io/library/alpine:${ALPINE_VERSION}@${ALPINE_DIGEST}" \
      io.roessner.openldap.version="${OPENLDAP_VERSION}" \
      io.roessner.openldap.channel="${OPENLDAP_CHANNEL}" \
      io.roessner.openldap.image-revision="${IMAGE_REVISION}"

RUN apk upgrade --no-cache \
    && apk add --no-cache \
        argon2-libs \
        ca-certificates \
        cyrus-sasl \
        libltdl \
        libuuid \
        openssl \
        su-exec \
    && case "${OPENLDAP_VERSION}" in \
         2.6.*) apk add --no-cache unixodbc ;; \
       esac \
    && addgroup -S ldap \
    && adduser -S -D -H -h /var/lib/openldap -s /sbin/nologin -G ldap ldap \
    && mkdir -p \
        /docker-entrypoint-initdb.d \
        /etc/openldap/certs \
        /etc/openldap/custom-config/pre \
        /etc/openldap/custom-config/post \
        /etc/openldap/custom-schema \
        /var/lib/openldap/accesslog \
        /var/lib/openldap/openldap-data \
        /var/run/openldap

COPY --from=builder /tmp/out/ /
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY docker-healthcheck.sh /usr/local/bin/docker-healthcheck.sh

RUN ln -sf ../lib/openldap/slapd /usr/sbin/slapd \
    && chown -R ldap:ldap \
        /docker-entrypoint-initdb.d \
        /etc/openldap \
        /var/lib/openldap \
        /var/run/openldap \
    && chmod 0755 /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-healthcheck.sh

USER ldap:ldap

EXPOSE 389 636

HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=5 \
  CMD ["/usr/local/bin/docker-healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["slapd"]
