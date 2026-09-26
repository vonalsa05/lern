#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$PROJECT_DIR"

BACKUP_DIR="${BACKUP_DIR:-$PROJECT_DIR/backups}"

PG_USER="${POSTGRES_USER:-appuser}"
PG_DB="${POSTGRES_DB:-appdb}"
DB_SERVICE="${DB_SERVICE:-db}"

usage() {
    cat <<EOF
Usage:
  $0 backup
  $0 restore <backup-file>
  $0 cycle

Environment:
  BACKUP_DIR    backup directory
  POSTGRES_USER PostgreSQL user
  POSTGRES_DB   PostgreSQL database
  DB_SERVICE    Docker Compose database service
EOF
}

compose() {
    docker compose "$@"
}

wait_for_db() {
    local i

    for i in $(seq 1 60); do
        if compose exec -T "$DB_SERVICE" \
            pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    echo "PostgreSQL не стал готовым за 60 секунд" >&2
    return 1
}

backup() {
    mkdir -p "$BACKUP_DIR"

    local backup_file
    backup_file="$BACKUP_DIR/${PG_DB}-$(date '+%Y-%m-%d_%H%M%S').dump"

    echo "Создаю backup: $backup_file"

    compose exec -T "$DB_SERVICE" \
        pg_dump \
        -U "$PG_USER" \
        -d "$PG_DB" \
        -Fc \
        > "$backup_file"

    test -s "$backup_file"

    echo "Backup успешно создан:"
    echo "  $backup_file"
}

restore() {
    local backup_file="${1:-}"

    if [[ -z "$backup_file" ]]; then
        echo "Укажи backup-файл" >&2
        usage
        exit 2
    fi

    if [[ ! -f "$backup_file" ]]; then
        echo "Backup не найден: $backup_file" >&2
        exit 1
    fi

    echo "Запускаю PostgreSQL..."
    compose up -d "$DB_SERVICE"

    wait_for_db

    echo "Восстанавливаю: $backup_file"

    compose exec -T "$DB_SERVICE" \
        pg_restore \
        --clean \
        --if-exists \
        --no-owner \
        --no-privileges \
        -U "$PG_USER" \
        -d "$PG_DB" \
        < "$backup_file"

    echo "Restore завершён успешно."
}

cycle() {
    local backup_file
    local probe_code
    local restored_count

    mkdir -p "$BACKUP_DIR"

    probe_code="backup-restore-$(date '+%s')"

    echo "1. Проверяю, что PostgreSQL работает..."
    compose up -d "$DB_SERVICE"
    wait_for_db

    echo "2. Записываю тестовую строку..."

    compose exec -T "$DB_SERVICE" \
        psql \
        -U "$PG_USER" \
        -d "$PG_DB" \
        -v ON_ERROR_STOP=1 \
        -c "INSERT INTO links (code, url)
            VALUES ('$probe_code', 'https://example.org/backup-restore')
            ON CONFLICT (code) DO UPDATE
            SET url = EXCLUDED.url"

    echo "3. Создаю backup..."

    backup_file="$BACKUP_DIR/${PG_DB}-cycle-$(date '+%Y-%m-%d_%H%M%S').dump"

    compose exec -T "$DB_SERVICE" \
        pg_dump \
        -U "$PG_USER" \
        -d "$PG_DB" \
        -Fc \
        > "$backup_file"

    test -s "$backup_file"

    echo "4. Уничтожаю контейнеры и volumes..."

    compose down -v

    echo "5. Поднимаю чистую PostgreSQL..."

    compose up -d "$DB_SERVICE"
    wait_for_db

    echo "6. Восстанавливаю backup..."

    compose exec -T "$DB_SERVICE" \
        pg_restore \
        --clean \
        --if-exists \
        --no-owner \
        --no-privileges \
        -U "$PG_USER" \
        -d "$PG_DB" \
        < "$backup_file"

    echo "7. Проверяю восстановленные данные..."

    restored_count="$(
        compose exec -T "$DB_SERVICE" \
            psql \
            -U "$PG_USER" \
            -d "$PG_DB" \
            -tAc \
            "SELECT count(*) FROM links
             WHERE code = '$probe_code'
               AND url = 'https://example.org/backup-restore';"
    )"

    restored_count="${restored_count//[[:space:]]/}"

    if [[ "$restored_count" != "1" ]]; then
        echo "ОШИБКА: тестовая строка после restore не найдена" >&2
        exit 1
    fi

    echo "8. Тест пройден."
    echo "Данные пережили: dump -> down -v -> restore"
    echo "Backup: $backup_file"
}

case "${1:-}" in
    backup)
        backup
        ;;

    restore)
        restore "${2:-}"
        ;;

    cycle)
        cycle
        ;;

    -h|--help)
        usage
        ;;

    *)
        usage
        exit 2
        ;;
esac