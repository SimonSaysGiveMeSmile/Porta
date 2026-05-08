.PHONY: help up down backend web test lint fmt

help:
	@echo "Targets:"
	@echo "  up        - start infra (postgres, redis, coturn)"
	@echo "  down      - stop infra"
	@echo "  backend   - run backend API"
	@echo "  web       - run web receiver dev server"
	@echo "  test      - run all tests"
	@echo "  lint      - run linters"
	@echo "  fmt       - format all code"

up:
	docker compose -f infra/docker-compose.yml up -d

down:
	docker compose -f infra/docker-compose.yml down

backend:
	$(MAKE) -C backend run

web:
	cd web && npm run dev

test:
	$(MAKE) -C backend test
	cd web && npm test --if-present

lint:
	$(MAKE) -C backend lint

fmt:
	$(MAKE) -C backend fmt
