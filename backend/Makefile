.PHONY: run build test lint fmt migrate tidy

run:
	go run ./cmd/porta

build:
	CGO_ENABLED=0 go build -o bin/porta ./cmd/porta

test:
	go test ./... -race -count=1

lint:
	go vet ./...

fmt:
	gofmt -s -w .

tidy:
	go mod tidy

migrate:
	go run ./cmd/porta -migrate
