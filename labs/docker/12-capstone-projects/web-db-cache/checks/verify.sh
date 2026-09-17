#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$PROJECT_DIR"

if [[ -z "${COMPOSE_FILE:-}" && ! -f compose.yaml && ! -f docker-compose.yaml ]]; then
    printf 'не нашёл compose.yaml в %s — переопредели PROJECT_DIR или COMPOSE_FILE\n' "$PROJECT_DIR" >&2
    exit 2
fi

API_URL="${API_URL:-http://localhost:8080}"
API_SERVICE="${API_SERVICE:-api}"
DB_SERVICE="${DB_SERVICE:-db}"
PG_USER="${POSTGRES_USER:-appuser}"
PG_DB="${POSTGRES_DB:-appdb}"
SKIP_DESTRUCTIVE=0

usage() {
    cat <<USAGE
Usage: $0 [--quick]

  --quick   пропустить проверки, которые останавливают и перезапускают сервисы

Переменные окружения: API_URL, API_SERVICE, DB_SERVICE, POSTGRES_USER, POSTGRES_DB
USAGE
}

case "${1:-}" in
    --quick) SKIP_DESTRUCTIVE=1 ;;
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) usage; exit 2 ;;
esac

passed=0
failed=0
failed_names=()

if [[ -t 1 ]]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; DIM=""; RESET=""
fi

ok() {
    printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"
    passed=$((passed + 1))
}

bad() {
    printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"
    [[ -n "${2:-}" ]] && printf '      %s%s%s\n' "$DIM" "$2" "$RESET"
    failed=$((failed + 1))
    failed_names+=("$1")
}

section() {
    printf '\n%s\n' "$1"
}

http_code() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || echo 000
}

compose() {
    docker compose "$@"
}

psql_q() {
    compose exec -T "$DB_SERVICE" psql -U "$PG_USER" -d "$PG_DB" -tAc "$1" 2>/dev/null
}

container_ids() {
    compose ps -q 2>/dev/null
}

wait_for_db() {
    local i
    for i in $(seq 1 60); do
        if psql_q 'select 1' | grep -q '^1$'; then
            return 0
        fi
        sleep 1
    done
    return 1
}

restore_db() {
    if [[ "$(compose ps --status running --services 2>/dev/null | grep -cx "$DB_SERVICE" || true)" == "0" ]]; then
        printf '%s  восстанавливаю %s...%s\n' "$DIM" "$DB_SERVICE" "$RESET"
        compose start "$DB_SERVICE" >/dev/null 2>&1 || true
    fi
}

trap restore_db EXIT

section "1. Стек поднят"
ids="$(container_ids)"
if [[ -z "$ids" ]]; then
    bad "контейнеры проекта запущены" "docker compose ps пуст — сначала docker compose up -d"
    printf '\n%sПроверять нечего.%s\n' "$RED" "$RESET"
    exit 1
fi
for id in $ids; do
    name="$(docker inspect "$id" --format '{{.Name}}' | sed 's|^/||')"
    status="$(docker inspect "$id" --format '{{.State.Status}}')"
    health="$(docker inspect "$id" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}')"
    if [[ "$status" == "running" && ( "$health" == "healthy" || "$health" == "-" ) ]]; then
        ok "$name: $status${health:+ ($health)}"
    else
        bad "$name: $status ($health)" "docker compose logs $name"
    fi
done

section "2. HTTP-контракт на живом стеке"
code="$(http_code "$API_URL/healthz")"
[[ "$code" == "200" ]] && ok "GET /healthz -> 200" || bad "GET /healthz -> 200" "получено $code"

code="$(http_code "$API_URL/readyz")"
[[ "$code" == "200" ]] && ok "GET /readyz -> 200" || bad "GET /readyz -> 200" "получено $code"

code="$(http_code "$API_URL/metrics")"
if [[ "$code" == "200" ]] && curl -s --max-time 10 "$API_URL/metrics" | grep -q '^# TYPE'; then
    ok "GET /metrics отдаёт метрики приложения"
else
    bad "GET /metrics отдаёт метрики приложения" "получено $code; мониторинг без метрик сервиса не отвечает на вопрос «почему медленно»"
fi

section "3. Миграции схемы"
tables="$(psql_q "select count(*) from information_schema.tables where table_schema='public'" || echo 0)"
tables="${tables//[^0-9]/}"
if [[ "${tables:-0}" -gt 0 ]]; then
    ok "в $PG_DB есть таблицы: ${tables}"
else
    bad "миграции применяются при старте" "в схеме public нет ни одной таблицы"
fi

section "4. Образы и политика релиза"
pulled_bad=(); built_bad=()
while read -r img; do
    [[ -z "$img" ]] && continue
    if [[ "$img" == *:latest ]]; then
        pulled_bad+=("$img")
    elif [[ "$img" != *:* ]]; then
        if [[ "$(docker image inspect "$img" --format '{{len .RepoDigests}}' 2>/dev/null || echo 1)" == "0" ]]; then
            built_bad+=("$img")
        else
            pulled_bad+=("$img")
        fi
    fi
done < <(compose config --images 2>/dev/null | sort -u)

[[ ${#pulled_bad[@]} -eq 0 ]] && ok "внешние образы с явным тегом, без latest" || bad "внешние образы с явным тегом, без latest" "${pulled_bad[*]}"
[[ ${#built_bad[@]} -eq 0 ]] && ok "собранный образ получает релизный тег" || bad "собранный образ получает релизный тег" "${built_bad[*]} — нужен image: <name>:<semver> рядом с build:"

section "5. Лимиты, логи, restart policy, пользователь"
no_mem=(); no_restart=(); no_logrotate=(); as_root=(); env_secrets=()
for id in $ids; do
    name="$(docker inspect "$id" --format '{{.Name}}' | sed 's|^/||')"
    [[ "$(docker inspect "$id" --format '{{.HostConfig.Memory}}')" == "0" ]] && no_mem+=("$name")
    policy="$(docker inspect "$id" --format '{{.HostConfig.RestartPolicy.Name}}')"
    [[ "$policy" == "no" || -z "$policy" ]] && no_restart+=("$name")
    [[ -z "$(docker inspect "$id" --format '{{index .HostConfig.LogConfig.Config "max-size"}}')" ]] && no_logrotate+=("$name")
    if docker inspect "$id" --format '{{range .Config.Env}}{{println .}}{{end}}' \
        | grep -qiE '(password|secret|token)=.+|://[^:/@]+:[^@]+@'; then
        env_secrets+=("$name")
    fi
done
user="$(docker inspect "$(compose ps -q "$API_SERVICE")" --format '{{.Config.User}}' 2>/dev/null || echo '')"
[[ -z "$user" || "$user" == "root" || "$user" == "0" ]] && as_root+=("$API_SERVICE")

[[ ${#no_mem[@]} -eq 0 ]] && ok "resource limits у всех сервисов" || bad "resource limits у всех сервисов" "без лимита: ${no_mem[*]}"
[[ ${#no_logrotate[@]} -eq 0 ]] && ok "ротация логов у всех сервисов" || bad "ротация логов у всех сервисов" "без max-size: ${no_logrotate[*]}"
[[ ${#no_restart[@]} -eq 0 ]] && ok "restart policy выставлена" || bad "restart policy выставлена" "restart=no: ${no_restart[*]} — стек не переживёт reboot"
[[ ${#as_root[@]} -eq 0 ]] && ok "$API_SERVICE работает не от root" || bad "$API_SERVICE работает не от root" "Config.User пуст"
[[ ${#env_secrets[@]} -eq 0 ]] && ok "секретов в environment нет" || bad "секретов в environment нет" "видно в docker inspect: ${env_secrets[*]}"

if [[ "$SKIP_DESTRUCTIVE" == "1" ]]; then
    section "6-7. Пропущены (--quick)"
else
    section "6. Readiness честно краснеет при мёртвой зависимости"
    compose stop "$DB_SERVICE" >/dev/null 2>&1
    sleep 2
    code="$(http_code "$API_URL/readyz")"
    live="$(http_code "$API_URL/healthz")"
    compose start "$DB_SERVICE" >/dev/null 2>&1
    wait_for_db || true
    if [[ "$code" == "503" ]]; then
        ok "БД погашена -> GET /readyz -> 503"
    else
        bad "БД погашена -> GET /readyz -> 503" "получено $code: балансировщик продолжит слать трафик в нерабочий инстанс"
    fi
    [[ "$live" == "200" ]] && ok "БД погашена -> GET /healthz остаётся 200" || bad "БД погашена -> GET /healthz остаётся 200" "получено $live: liveness не должен зависеть от БД, иначе рестарт-петля"

    section "7. Данные переживают перезапуск"
    if psql_q 'create table if not exists verify_probe(id int primary key); insert into verify_probe values (1) on conflict do nothing;' >/dev/null; then
        compose restart "$DB_SERVICE" >/dev/null 2>&1
        if wait_for_db; then
            rows="$(psql_q 'select count(*) from verify_probe' || echo 0)"
            rows="${rows//[^0-9]/}"
            [[ "${rows:-0}" -ge 1 ]] && ok "строка на месте после docker compose restart $DB_SERVICE" || bad "строка на месте после docker compose restart $DB_SERVICE" "данные потеряны — проверь volume"
            psql_q 'drop table verify_probe' >/dev/null || true
        else
            bad "БД поднялась после restart" "wait_for_db истёк"
        fi
    else
        bad "запись тестовой строки в $PG_DB" "psql недоступен"
    fi
fi

section "Итог"
printf '  пройдено: %s%d%s, провалено: %s%d%s\n' "$GREEN" "$passed" "$RESET" "$RED" "$failed" "$RESET"
if [[ "$failed" -gt 0 ]]; then
    printf '\n  Не выполнено:\n'
    for name in "${failed_names[@]}"; do
        printf '   - %s\n' "$name"
    done
    printf '\n'
    exit 1
fi
printf '\n  Все проверки пройдены.\n\n'
