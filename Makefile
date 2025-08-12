SHELL = /bin/bash
.ONESHELL:

processors.up:
	@docker compose -f payment-processor/docker-compose.yml up -d

processors.down:
	@docker compose -f payment-processor/docker-compose.yml down --remove-orphans

firebrand.up:
	@docker compose up -d

firebrand.down:
	@docker compose down -v

rinha.test:
	@k6 run rinha-test/rinha.js