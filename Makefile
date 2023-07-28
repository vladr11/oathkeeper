SHELL=/bin/bash -o pipefail

AWS_ACCOUNT_NUMBER=966512032124
export GO111MODULE := on
export PATH := .bin:${PATH}
IMAGE_REPO=${AWS_ACCOUNT_NUMBER}.dkr.ecr.eu-central-1.amazonaws.com/oathkeeper


.PHONY: go-install-dependencies
go-install-dependencies:
	go mod download

.PHONY: build
go-build:
	go build -o ${OUTPUT_NAME}

.PHONY: goformat
go-format:
	go fmt ./...

.PHONY: go-lint
go-lint:
	golint -set_exit_status ./...

.PHONY: go-test
go-test: 
	go test ./...

go-pre-commit: go-format go-lint go-test

.PHONY: deps
deps:
ifneq ("$(shell base64 Makefile))","$(shell cat .bin/.lock)")
		go build -o .bin/go-acc github.com/ory/go-acc
		go build -o .bin/listx github.com/ory/x/tools/listx
		go build -o .bin/mockgen github.com/golang/mock/mockgen
		go build -o .bin/swagger github.com/go-swagger/go-swagger/cmd/swagger
		go build -o .bin/goimports golang.org/x/tools/cmd/goimports
		echo "v0" > .bin/.lock
		echo "$$(base64 Makefile)" > .bin/.lock
endif

# Formats the code
.PHONY: format
format: deps
		goreturns -w -local github.com/ory $$(listx .)

.PHONY: gen
gen:
		mocks sdk

# Generates the SDKs
.PHONY: sdk
sdk: deps
		swagger generate spec -m -o ./.schema/api.swagger.json -x internal/httpclient
		ory dev swagger sanitize ./.schema/api.swagger.json
		swagger flatten --with-flatten=remove-unused -o ./.schema/api.swagger.json ./.schema/api.swagger.json
		swagger validate ./.schema/api.swagger.json
		rm -rf internal/httpclient
		mkdir -p internal/httpclient
		swagger generate client -f ./.schema/api.swagger.json -t internal/httpclient -A Ory_Oathkeeper
		make format

.PHONY: install-stable
install-stable: deps
		OATHKEEPER_LATEST=$$(git describe --abbrev=0 --tags)
		git checkout $$OATHKEEPER_LATEST
		packr2
		GO111MODULE=on go install \
				-ldflags "-X github.com/ory/oathkeeper/x.Version=$$OATHKEEPER_LATEST -X github.com/ory/oathkeeper/x.Date=`TZ=UTC date -u '+%Y-%m-%dT%H:%M:%SZ'` -X github.com/ory/oathkeeper/x.Commit=`git rev-parse HEAD`" \
				.
		packr2 clean
		git checkout master

.PHONY: install
install: deps
		packr2 || (GO111MODULE=on go mod download github.com/gobuffalo/packr/v2/packr2 && packr2)
		GO111MODULE=on go install .
		packr2 clean

image-uri:
    export IMAGE_URI:=$(IMAGE_REPO):$(TAG)

.PHONY: docker
docker: deps image-uri
		go install github.com/gobuffalo/packr/v2/packr2@latest && packr2
		CGO_ENABLED=0 GO111MODULE=on GOOS=linux GOARCH=amd64 go build
		packr2 clean
		docker build -t $(IMAGE_URI) .
		docker build -t $(IMAGE_URI)-alpine -f Dockerfile-alpine .
		rm oathkeeper

docker-push: docker
	aws ecr get-login-password --region $(AWS_DEFAULT_REGION) | docker login --username AWS --password-stdin $(AWS_ACCOUNT_NUMBER).dkr.ecr.$(AWS_DEFAULT_REGION).amazonaws.com
	docker push $(IMAGE_URI)
	docker push $(IMAGE_URI)-alpine
	echo "Uncompressed image size $$(docker images $(IMAGE_URI) --format='{{.Size}}') (compressed about 3x smaller)"
