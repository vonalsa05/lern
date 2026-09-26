#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$PROJECT_DIR"

usage() {
    cat <<EOF
Usage:
  $0 db-latency
  $0 cache-down
  $0 reset
EOF
}

toxiproxy() {
    docker compose exec -T toxiproxy /toxiproxy-cli "$@"
}

run_slo() {
    docker compose --profile load run --rm k6 run /scripts/slo.js
}

reset() {
    echo "Сбрасываю chaos..."

    toxiproxy toxic remove -n db_latency db 2>/dev/null || true
    toxiproxy toxic remove -n cache_reset cache 2>/dev/null || true

    echo "Chaos отключён."
}

db_latency() {
    reset

    echo "Добавляю 300 ms latency к PostgreSQL..."

    toxiproxy toxic add \
        -t latency \
        -n db_latency \
        -a latency=300 \
        db

    trap reset EXIT

    run_slo
}

cache_down() {
    reset

    echo "Ломаю Redis..."

    toxiproxy toxic add \
        -t reset_peer \
        -n cache_reset \
        cache

    trap reset EXIT

    run_slo
}

case "${1:-}" in
    db-latency)
        db_latency
        ;;

    cache-down)
        cache_down
        ;;

    reset)
        reset
        ;;

    -h|--help)
        usage
        ;;

    *)
        usage
        exit 2
        ;;
esac
