IMAGE_NAME ?= openldap
CHANNEL ?= lts
VERSION_FILE := versions/openldap-$(CHANNEL).env
include versions/alpine.env
include $(VERSION_FILE)

TAG ?= $(CHANNEL)
BUILD_ARGS := \
	--build-arg ALPINE_VERSION=$(ALPINE_VERSION) \
	--build-arg ALPINE_DIGEST=$(ALPINE_DIGEST) \
	--build-arg OPENLDAP_CHANNEL=$(OPENLDAP_CHANNEL) \
	--build-arg OPENLDAP_VERSION=$(OPENLDAP_VERSION) \
	--build-arg OPENLDAP_SHA256=$(OPENLDAP_SHA256) \
	--build-arg IMAGE_REVISION=$(IMAGE_REVISION)
EXAMPLE_CERT_DIR := examples/certs
EXAMPLE_TLS_CERT := $(EXAMPLE_CERT_DIR)/tls.crt
EXAMPLE_TLS_KEY := $(EXAMPLE_CERT_DIR)/tls.key
EXAMPLE_TLS_CA := $(EXAMPLE_CERT_DIR)/ca.crt

.PHONY: build push sbom-local sbom-registry check-release-contract run compose-up compose-down compose-cert

build:
	docker build $(BUILD_ARGS) -t $(IMAGE_NAME):$(TAG) .

push:
	docker buildx build \
	  --platform linux/amd64,linux/arm64 \
	  --pull \
	  $(BUILD_ARGS) \
	  --attest type=provenance,mode=max \
	  --attest type=sbom \
	  -t $(IMAGE_NAME):$(TAG) \
	  --push .

sbom-local:
	rm -rf dist/sbom-local
	docker buildx build \
	  --sbom=true \
	  $(BUILD_ARGS) \
	  --output type=local,dest=dist/sbom-local .

sbom-registry:
	mkdir -p dist/sbom
	docker buildx imagetools inspect $(IMAGE_NAME):$(TAG) \
	  --format '{{ json .SBOM }}' > dist/sbom/$(TAG).sbom.json

check-release-contract:
	tests/check-release-contract.sh

run:
	docker run --rm -it \
	  --name openldap \
	  -p 389:389 -p 636:636 \
	  --env-file .env \
	  -v $$(pwd)/data/openldap:/var/lib/openldap/openldap-data \
	  -v $$(pwd)/data/accesslog:/var/lib/openldap/accesslog \
	  -v $$(pwd)/examples/bootstrap:/docker-entrypoint-initdb.d:ro \
	  $(IMAGE_NAME):$(TAG)

compose-cert:
	mkdir -p $(EXAMPLE_CERT_DIR)
	openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
	  -days 7 \
	  -subj '/CN=localhost' \
	  -addext 'subjectAltName=DNS:localhost,DNS:openldap,IP:127.0.0.1' \
	  -keyout $(EXAMPLE_TLS_KEY) \
	  -out $(EXAMPLE_TLS_CERT)
	cp $(EXAMPLE_TLS_CERT) $(EXAMPLE_TLS_CA)
	chmod 0644 $(EXAMPLE_TLS_CERT) $(EXAMPLE_TLS_KEY) $(EXAMPLE_TLS_CA)

compose-up: compose-cert
	ALPINE_VERSION=$(ALPINE_VERSION) \
	ALPINE_DIGEST=$(ALPINE_DIGEST) \
	OPENLDAP_CHANNEL=$(OPENLDAP_CHANNEL) \
	OPENLDAP_VERSION=$(OPENLDAP_VERSION) \
	OPENLDAP_SHA256=$(OPENLDAP_SHA256) \
	IMAGE_REVISION=$(IMAGE_REVISION) \
	IMAGE_NAME=$(IMAGE_NAME) TAG=$(TAG) \
	docker compose -f examples/docker-compose.yml up --build

compose-down:
	IMAGE_NAME=$(IMAGE_NAME) TAG=$(TAG) docker compose -f examples/docker-compose.yml down -v
	rm -f $(EXAMPLE_TLS_CERT) $(EXAMPLE_TLS_KEY) $(EXAMPLE_TLS_CA)
