.PHONY: smoke load chaos-db chaos-cache chaos-reset

prepare-load:
	mkdir -p load/results
	chmod 0777 load/results

smoke: prepare-load
	docker compose --profile load run --rm k6 run /scripts/smoke.js

load: prepare-load
	docker compose --profile load run --rm k6 run /scripts/slo.js

chaos-db: prepare-load
	./scripts/chaos.sh db-latency

chaos-cache: prepare-load
	./scripts/chaos.sh cache-down

chaos-reset:
	./scripts/chaos.sh reset
