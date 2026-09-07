up:
	docker compose up -d --build

down:
	docker compose down -v

test:
	curl -f http://localhost:8080/healthz
	curl -f http://localhost:8080/readyz

verify:
	./checks/verify.sh

logs:
	docker compose logs

ps:
	docker compose ps
