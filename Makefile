IMAGE_NAME ?= openldap-alpine-slapdconf
TAG ?= latest

.PHONY: build push sbom-local sbom-registry run compose-up compose-down

build:
	docker build -t $(IMAGE_NAME):$(TAG) .

push:
	docker buildx build \
	  --platform linux/amd64,linux/arm64 \
	  --pull \
	  --attest type=provenance,mode=max \
	  --attest type=sbom \
	  -t $(IMAGE_NAME):$(TAG) \
	  --push .

sbom-local:
	rm -rf dist/sbom-local
	docker buildx build \
	  --sbom=true \
	  --output type=local,dest=dist/sbom-local .

sbom-registry:
	mkdir -p dist/sbom
	docker buildx imagetools inspect $(IMAGE_NAME):$(TAG) \
	  --format '{{ json .SBOM }}' > dist/sbom/$(TAG).sbom.json

run:
	docker run --rm -it \
	  --name openldap \
	  -p 389:389 -p 636:636 \
	  --env-file .env \
	  -v $$(pwd)/data/openldap:/var/lib/openldap/openldap-data \
	  -v $$(pwd)/data/accesslog:/var/lib/openldap/accesslog \
	  -v $$(pwd)/examples/bootstrap:/docker-entrypoint-initdb.d:ro \
	  $(IMAGE_NAME):$(TAG)

compose-up:
	docker compose -f examples/docker-compose.yml up --build

compose-down:
	docker compose -f examples/docker-compose.yml down -v
