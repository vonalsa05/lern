# web-db-cache: разбор проекта, чтобы вернуть его в голову

> Как читать: сначала часть 1 (картина целиком, 10 минут), потом часть 2 по файлам **с открытым файлом рядом**, потом часть 3 (история твоих правок). В конце, в части 5, есть вопросы для самопроверки: если на них отвечаешь без подсказки, проект снова твой.
>
> Пометки: **⚠️** — важное замечание (баг, риск, неточность); **💡** — пояснение «почему так»; **🔎 проверь** — то, что я вывел из кода, но не проверил запуском (Docker в моей среде недоступен).

---

# Часть 1. Проект простыми словами

## 1.1. Что это вообще

Это **сокращатель ссылок**. Ты отправляешь длинный URL и получаешь короткий код `aB3xY9k`. Потом по коду получаешь URL обратно.

Сам сервис намеренно простой. Главное в проекте — **стенд вокруг сервиса**, который умеет:
1. подниматься одной командой;
2. показывать, что происходит внутри (метрики, графики, алерты);
3. нагружать сервис и проверять, укладывается ли он в целевые показатели (SLO);
4. ломать зависимости (медленная БД, мёртвый кэш) и смотреть, как сервис это переживает;
5. делать бэкап и восстанавливать базу.

## 1.2. Аналогия: библиотека

| В проекте | В библиотеке |
|---|---|
| `api` (FastAPI) | Библиотекарь у стойки |
| `db` (PostgreSQL) | Архив в подвале: всё хранится надёжно, но идти туда долго |
| `cache` (Redis) | Полка у стойки с популярными книгами: быстро, но место ограничено, и книги с неё периодически убирают (TTL 60 секунд) |
| `migrate` | Завхоз, который утром перед открытием расставляет в архиве стеллажи (создаёт таблицу) и уходит |
| `toxiproxy` | Коридор между стойкой и архивом/полкой, в котором можно «выключить свет» или «поставить турникет» |
| `prometheus` | Бухгалтер, который каждые 15 секунд обходит всех и записывает показания счётчиков |
| `grafana` | Табло с графиками по записям бухгалтера |
| `alertmanager` | Пожарная сигнализация (у тебя пока без сирены: сигнал никуда не уходит) |
| `postgres-exporter`, `redis-exporter`, `cadvisor` | Датчики на архиве, полке и на здании в целом |
| `k6` | Толпа посетителей, которую можно пустить с заданной интенсивностью |
| `db-backup-restore.sh` | Ксерокопия архива и восстановление из неё |
| `checks/verify.sh` | Инспектор, который проходит по чек-листу и говорит «сдано / не сдано» |

## 1.3. Базовые понятия Docker, на которых всё стоит

- **Образ (image)** — «слепок» файловой системы и команды запуска. Например, `postgres:16-alpine` — готовый образ Postgres 16 на базе Alpine Linux.
- **Контейнер** — запущенный экземпляр образа. Из одного образа можно запустить много контейнеров. Например, `db` и `migrate` оба из `postgres:16-alpine`, но делают разное.
- **Compose (`compose.yaml`)** — файл, где описано *несколько* контейнеров и связи между ними. `docker compose up -d` поднимает всё сразу.
- **Сервис** — запись в `compose.yaml` (`api:`, `db:` …). Имя сервиса одновременно служит **DNS-именем внутри сети**: контейнер `api` может обратиться к `db` просто по адресу `db:5432`.
- **Сеть** — compose сам создаёт сеть `web-db-cache_default` (имя = имя папки + `_default`) и подключает туда всех. Поэтому сервисы видят друг друга по именам.
- **Порт `"8080:8080"`** — «хост:контейнер». Левая часть — порт на твоём компьютере, правая — внутри контейнера. Если `ports` нет, сервис доступен **только** другим контейнерам, а с твоего компьютера — нет. У `db` и `cache` портов нет, и это правильно.
- **Volume** — хранилище, которое переживает удаление контейнера. `pg_data:/var/lib/postgresql/data` означает: данные Postgres лежат в томе `pg_data`, а не внутри контейнера. `docker compose down` тома сохраняет, `down -v` удаляет.
- **Bind mount** `./prometheus:/etc/prometheus:ro` — папка с твоего диска, «проброшенная» в контейнер. `:ro` = только чтение.
- **Healthcheck** — команда, которую Docker периодически запускает внутри контейнера. Код выхода 0 означает `healthy`, иначе `unhealthy`.
- **`depends_on` + `condition`** — порядок запуска: «не стартуй, пока тот сервис не станет healthy / не завершится успешно».

## 1.4. Что происходит при `docker compose up -d` (по шагам)

```
t=0   Стартуют сразу (у них нет зависимостей):
      db, cache, toxiproxy, prometheus, alertmanager, cadvisor

t≈5с  db становится healthy (pg_isready ok)
      → стартуют migrate и postgres-exporter
      cache становится healthy (redis-cli ping ok)
      → стартует redis-exporter
      toxiproxy становится healthy (toxiproxy-cli list ok)
      prometheus становится healthy → стартует grafana

t≈6с  migrate выполняет CREATE TABLE IF NOT EXISTS links ... и завершается с кодом 0
      → условие service_completed_successfully выполнено

      api стартует (дождавшись: migrate завершился, cache healthy, toxiproxy healthy)

t≈15с HEALTHCHECK api (из Dockerfile) дёргает /healthz → api healthy
```

`k6` при этом **не стартует**: у него `profiles: [load]`, он поднимается только командами вида `docker compose --profile load run k6 ...` (то есть через `make smoke` / `make load`).

## 1.5. Что происходит при одном запросе `GET /links/aB3xY9k`

```
curl → localhost:8080 → [api]
                         │ 1. middleware засекает время
                         │ 2. Redis: GET aB3xY9k     (через toxiproxy:16379 → cache:6379)
                         │    ├─ есть → ответ {"url":..., "source":"cache"} + X-Cache: HIT
                         │    └─ нет  → 3. Postgres: SELECT url FROM links WHERE code='aB3xY9k'
                         │                 (через toxiproxy:15432 → db:5432)
                         │              ├─ нет строки → 404
                         │              └─ есть → 4. Redis: SET aB3xY9k <url> EX 60
                         │                        ответ {"url":..., "source":"db"} + X-Cache: MISS
                         │ 5. middleware записывает метрики (счётчик + время)
                         ▼
Prometheus раз в 15 с забирает /metrics → Grafana рисует графики
```

Это паттерн **cache-aside (read-through)**: сначала смотрим в кэш, при промахе идём в БД и кладём результат в кэш на 60 секунд.

## 1.6. Карта «кто к кому ходит»

```
api ──► toxiproxy ──► db        (DATABASE_URL = ...@toxiproxy:15432/...)
api ──► toxiproxy ──► cache     (REDIS_URL = redis://toxiproxy:16379)
migrate ─────────────► db       (напрямую, psql -h db)
postgres-exporter ───► db       (напрямую)
redis-exporter ──────► cache    (напрямую)
prometheus ──► api, cadvisor, postgres-exporter, redis-exporter, сам себя
prometheus ──► alertmanager     (отправляет алерты)
grafana ─────► prometheus       (читает данные)
k6 ──────────► api
```

💡 **Почему экспортёры ходят напрямую, а api через toxiproxy.** Toxiproxy «портит дорогу» только для api. Во время хаоса экспортёры покажут, что БД и Redis сами по себе здоровы, а метрики api покажут, что до них плохо добираться. Так и отличают «сломалась БД» от «сломалась сеть до БД».

---
# Часть 2. Разбор каждого файла

Порядок: от «скелета» (compose, Dockerfile) к «мясу» (main.py), потом наблюдаемость, потом инструменты вокруг.

---

## 2.1. `compose.yaml` — описание всего стека

### Синтаксис YAML за 1 минуту
```yaml
ключ: значение          # словарь (map)
ключ:
  вложенный: значение   # вложенность задаётся ОТСТУПОМ (пробелами, не табами)
список:
  - элемент1            # "- " = элемент списка
  - элемент2
список2: ["a", "b"]     # тот же список в одну строку (flow-стиль)
текст: |                # "|" = многострочная строка как есть (используется в rules/api.yml)
  строка 1
  строка 2
"8080:8080"             # кавычки нужны, чтобы YAML не понял значение как число/время
```

### Сервис `api` (разбираю каждый ключ; у остальных сервисов повторяется то же самое)

```yaml
  api:
    build: .                     # собрать образ из Dockerfile в текущей папке
    image: web-db-cache:1.0.0    # как назвать собранный образ (имя:тег)
```
💡 `build` + `image` вместе означают «собери и повесь тег». Без `image` образ получил бы автоимя `web-db-cache-api:latest`. Тег `1.0.0` — это «релизная версия» из REVIEW.

```yaml
    restart: unless-stopped
```
Если контейнер упал или машина перезагрузилась, Docker перезапустит его сам. Исключение: ты остановил его вручную (`docker stop`). Другие варианты: `"no"` (никогда), `always`, `on-failure`.

```yaml
    read_only: true              # корневая ФС контейнера только для чтения
    tmpfs:
      - /tmp                     # ...кроме /tmp: он в оперативке и доступен на запись
    cap_drop:
      - ALL                      # отобрать у процесса все Linux capabilities (привилегии root)
    security_opt:
      - no-new-privileges:true   # процесс не может повысить себе права (setuid и т.п.)
```
💡 Это «харденинг» контейнера. Если в приложении найдут уязвимость, атакующий не сможет ничего записать в ФС и ничего сделать от root. `/tmp` оставлен, потому что многим библиотекам нужен временный каталог.

```yaml
    ports:
      - "8080:8080"              # localhost:8080 на хосте → 8080 в контейнере
```
⚠️ Без указания IP порт слушает на **всех** интерфейсах (`0.0.0.0`), то есть доступен из сети, а не только с твоего компьютера. Для api это нормально, для служебных UI (Grafana, Prometheus и т.д.) — нет. Безопасный вариант: `"127.0.0.1:9090:9090"`.

```yaml
    environment:
      DATABASE_URL: postgres://appuser:apppass@toxiproxy:15432/appdb
      REDIS_URL: redis://toxiproxy:16379
```
Переменные окружения внутри контейнера; `main.py` читает их через `os.getenv`. Формат URL: `схема://пользователь:пароль@хост:порт/база`.
💡 Хост здесь `toxiproxy`, а не `db`: api ходит в БД через прокси (коммит `cf10908`).
⚠️ Пароль `apppass` лежит открытым текстом и виден в `docker inspect`.

```yaml
    depends_on:
      migrate:
        condition: service_completed_successfully   # migrate отработал и вышел с кодом 0
      cache:
        condition: service_healthy                  # healthcheck cache зелёный
      toxiproxy:
        condition: service_healthy
```
Прямой зависимости от `db` нет, но она есть транзитивно: `migrate` сам ждёт `db: service_healthy`.

```yaml
    deploy:
      resources:
        limits:
          cpus: "0.5"      # не больше половины одного ядра
          memory: 256M     # больше 256 МБ — ядро убьёт процесс (OOM kill)
```
💡 Лимиты нужны, чтобы один сервис не съел всю машину.

```yaml
    logging:
      driver: json-file
      options:
        max-size: "10m"    # файл лога не больше 10 МБ...
        max-file: "3"      # ...и хранить максимум 3 таких файла (ротация)
```
💡 Без этого логи контейнера растут бесконечно и однажды забивают диск.

Healthcheck у `api` в compose **не написан**: он берётся из `HEALTHCHECK` в Dockerfile.

### Сервис `db`
```yaml
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: appdb           # при ПЕРВОМ старте создать базу appdb
      POSTGRES_USER: appuser       # ...пользователя appuser
      POSTGRES_PASSWORD: apppass   # ...с этим паролем
    volumes:
      - pg_data:/var/lib/postgresql/data   # данные в именованном томе
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U appuser -d appdb"]
      interval: 5s     # проверять каждые 5 секунд
      timeout: 5s      # если команда висит дольше 5 с — считать провалом
      retries: 5       # 5 провалов подряд → unhealthy
```
💡 `POSTGRES_*` срабатывают **только при пустом томе**. Если поменять пароль в compose, а том `pg_data` уже есть, в базе останется старый пароль. Это частая ловушка.
💡 `CMD` vs `CMD-SHELL`: `CMD` запускает программу напрямую (`["CMD", "redis-cli", "ping"]`), `CMD-SHELL` — через `sh -c` (нужно, если есть пайпы, `||` и т.п.).
💡 Порта наружу нет: к БД ходят только контейнеры. Так и надо.

### Сервис `k6`
```yaml
  k6:
    image: grafana/k6:2.2.0
    profiles:
      - load                          # не поднимается при обычном `up`
    volumes:
      - ./load:/scripts:ro            # скрипты smoke.js/slo.js
      - ./load/results:/results       # сюда k6 пишет summary.json
    environment:
      API_URL: http://api:8080        # внутри сети api доступен по имени
    depends_on:
      api:
        condition: service_healthy
```
💡 Запускается одноразово: `docker compose --profile load run --rm k6 run /scripts/smoke.js`. `run` = запустить сервис с другой командой, `--rm` = удалить контейнер после завершения. `run /scripts/smoke.js` передаётся как аргументы в `ENTRYPOINT` образа (`k6`), то есть выполнится `k6 run /scripts/smoke.js`.
⚠️ Переменные `RPS`, `DURATION` и т.п. с хоста сами в контейнер **не попадают**. Нужно `docker compose --profile load run --rm -e RPS=100 k6 run /scripts/slo.js`.

### Сервис `toxiproxy`
```yaml
  toxiproxy:
    image: ghcr.io/shopify/toxiproxy:2.8.0
    volumes:
      - ./toxiproxy/toxiproxy.json:/etc/toxiproxy/toxiproxy.json:ro
    command:
      - "-config"
      - "/etc/toxiproxy/toxiproxy.json"   # при старте создать прокси из этого файла
    ports:
      - "8474:8474"                       # HTTP API управления toxiproxy
    healthcheck:
      test: ["CMD", "/toxiproxy-cli", "list"]
      start_period: 5s                    # первые 5 с провалы не считаются
```
⚠️ 🔎 **Возможно, порт 8474 с хоста не работает.** Насколько я помню Dockerfile образа Toxiproxy, там `ENTRYPOINT ["/toxiproxy"]` и `CMD ["-host=0.0.0.0"]`. Твой `command:` **заменяет** CMD целиком, флаг `-host=0.0.0.0` пропадает, и API слушает только `localhost` внутри контейнера. Healthcheck и `chaos.sh` при этом работают: они выполняются *внутри* контейнера через `exec`. Проверить: `curl localhost:8474/proxies` с хоста. Если соединение сбрасывается, догадка верна. Раз `chaos.sh` ходит через `exec`, публиковать 8474 наружу вообще не нужно. (В ONBOARDING.md я писал, что через 8474 «кто угодно может отравить БД». С учётом этой детали риск, скорее всего, ниже, но лучше просто убрать `ports`.)

### Сервис `migrate` — init-контейнер
```yaml
  migrate:
    image: postgres:16-alpine          # берём образ Postgres ради утилиты psql
    environment:
      PGPASSWORD: apppass              # psql берёт пароль из этой переменной
    volumes:
      - ./migrations:/migrations:ro
    depends_on:
      db:
        condition: service_healthy
    command:
      - sh
      - -c
      - psql -h db -U appuser -d appdb -f /migrations/001_init.sql
    restart: "no"                      # отработал и умер — это нормально
```
💡 Паттерн «init-контейнер»: запустился, применил схему, вышел с кодом 0. Api ждёт именно этого (`service_completed_successfully`).
⚠️ `psql -f` **без** `-v ON_ERROR_STOP=1` возвращает код 0, даже если SQL упал с ошибкой. Тогда api стартует на сломанной схеме. В `db-backup-restore.sh` ты этот флаг ставишь, а здесь нет.
⚠️ Путь к файлу захардкожен. Если появится `002_*.sql`, он не применится, пока не поправишь команду.

### Сервис `cache`
```yaml
  cache:
    image: redis:7-alpine
    command: ["redis-server", "--maxmemory", "200mb", "--maxmemory-policy", "allkeys-lru"]
    volumes:
      - redis_data:/data
```
💡 `maxmemory 200mb` — Redis сам ограничивает память (до лимита контейнера 256M остаётся запас). `allkeys-lru` — когда место кончится, выбросить давно не использованные ключи. Без этого Redis отвечал бы ошибкой на запись (`noeviction`) или контейнер убивал бы OOM.
⚠️ Том `redis_data` у кэша — вопрос: кэшу обычно не нужно переживать рестарт. Это осознанное решение или остаток? (Так же спрашивал REVIEW, К7.)

### `postgres-exporter`, `redis-exporter`
Переводят статистику Postgres/Redis в формат Prometheus. `DATA_SOURCE_NAME` / `REDIS_ADDR` — куда подключаться. Порты 9187/9121 наружу не открыты, Prometheus ходит к ним внутри сети.
⚠️ У них нет healthcheck (для `verify.sh` это нормально: он считает «нет healthcheck» допустимым).

### `prometheus`
```yaml
    volumes:
      - ./prometheus:/etc/prometheus:ro   # prometheus.yml и rules/ из репозитория
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:9090/-/ready"]
```
💡 `wget -qO-` = тихо скачать и вывести в stdout. Код выхода 0 только при HTTP 2xx.
⚠️ Нет тома под данные (`/prometheus`): при пересоздании контейнера история метрик теряется.

### `alertmanager`
Получает алерты от Prometheus и должен рассылать их (почта, Telegram, Slack…). Конфиг из `./alertmanager/alertmanager.yml`.

### `grafana`
```yaml
    volumes:
      #  volume ,   Grafana,          ← битый комментарий: кириллица потерялась
      #   dashboard'     .
      - grafana_data:/var/lib/grafana                      # внутренняя БД Grafana (юзеры, настройки)
      - ./grafana/provisioning:/etc/grafana/provisioning:ro # автонастройка datasource и дашбордов
      - ./grafana/dashboards:/etc/grafana/dashboards:ro     # JSON дашбордов
```
⚠️ Логин `admin/admin` по умолчанию, порт открыт на `0.0.0.0`.

### `cadvisor`
Метрики по всем контейнерам (CPU, память, сеть). Монтирует `/`, `/var/run`, `/sys` хоста только на чтение: так он видит, что происходит на машине.
⚠️ `/var/lib/docker` закомментирован, поэтому часть метрик (диск по контейнерам) неполная. `start_period: 90s` — cAdvisor долго стартует.

### Блок `volumes:` в конце
```yaml
volumes:
  pg_data:
  redis_data:
  grafana_data:
```
Объявление именованных томов. Docker создаст их как `web-db-cache_pg_data` и т.д.

---

## 2.2. `Dockerfile` — как собирается образ api

```dockerfile
FROM python:3.12-slim AS builder      # ЭТАП 1 "builder": базовый образ с Python
WORKDIR /build                        # cd /build (создаётся, если нет)
COPY requirements.txt .               # скопировать файл с хоста в образ
RUN pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt
                                      # скачать/собрать все пакеты в виде .whl-файлов в /wheels

FROM python:3.12-slim                 # ЭТАП 2 (финальный): начинаем с чистого образа
WORKDIR /app
RUN useradd --create-home --uid 10001 app   # создать пользователя app с uid 10001
COPY requirements.txt .
COPY --from=builder /wheels /wheels   # взять готовые колёса из этапа builder
RUN pip install --no-cache-dir --no-index --find-links=/wheels -r requirements.txt \
    && rm -rf /wheels                 # поставить ТОЛЬКО из локальных колёс (--no-index = без интернета)
COPY --chown=app:app app/ ./app/      # код приложения, владелец — app
USER app                              # дальше всё (и запуск) — от пользователя app, не root
EXPOSE 8080                           # документация: "слушаю 8080" (сам порт не открывает)
HEALTHCHECK --interval=10s --timeout=5s --retries=5 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz')" || exit 1
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
```

Разбор ключевого:
- **Multi-stage** (`AS builder` + второй `FROM`): в финальный образ попадает только то, что явно скопировано через `COPY --from`. Идея: компиляторы и мусор сборки остаются в первом этапе.
- **Порядок слоёв**: `requirements.txt` копируется *до* кода. Пока зависимости не меняются, Docker берёт слой с `pip install` из кэша, и пересборка после правки `main.py` занимает секунды.
- **`HEALTHCHECK`**: `urlopen` бросает исключение при ошибке соединения или коде ≥ 400, тогда Python выходит с кодом 1. Используется curl-подобная проверка через Python, потому что curl в slim-образе нет.
- **`CMD`**: `uvicorn` — ASGI-сервер. `app.main:app` = «из модуля `app/main.py` взять объект `app`». `--host 0.0.0.0` обязателен: с `127.0.0.1` api был бы недоступен из других контейнеров.

⚠️ **Multi-stage здесь почти не экономит место.** `COPY --from=builder /wheels /wheels` создаёт отдельный слой с колёсами. `rm -rf /wheels` в следующем `RUN` удаляет их только «поверх», а слой с колёсами остаётся в образе. Плюс все пакеты — готовые бинарные колёса (`psycopg[binary]`), компилировать нечего, так что builder ничего не компилирует. Если хочется реальной пользы: `RUN --mount=type=bind,from=builder,source=/wheels,target=/wheels pip install ...` (колёса не попадают в слой) или venv в builder и `COPY --from=builder /venv /venv`.
⚠️ Один процесс uvicorn, один воркер. Для учебного стенда нормально, но это одна из причин ограниченной пропускной способности (см. §2.4).

---

## 2.3. `requirements.txt`, `.dockerignore`, `.gitignore`

```
fastapi==0.136.1              # веб-фреймворк
uvicorn[standard]==0.53.0     # сервер; [standard] = extras: uvloop, httptools (быстрее)
psycopg[binary]==3.2.1        # драйвер PostgreSQL v3; [binary] = со встроенной libpq
redis==8.1.0                  # клиент Redis
prometheus-client==0.26.0     # метрики
```
💡 `==` = точная версия, сборка воспроизводима.
⚠️ Запинены только прямые зависимости. `starlette`, `pydantic`, `anyio` и другие транзитивные могут приехать другими. Полный lock делается через `pip freeze > requirements.lock` или `pip-compile`.

**`.dockerignore`** — что НЕ отправлять в контекст сборки (`docker build` отправляет демону всю папку). Исключены `.git`, кэши Python, venv, `.env`, `load/results`. 💡 Это ускоряет сборку и не даёт секретам попасть в образ.
⚠️ В проекте нет `.env` и `combined_output.txt`, строки для них — заготовка «на будущее» или остаток. Также не исключены `backups/`, `grafana/`, `prometheus/`, `*.md`. Сейчас это не вредно, потому что `COPY` берёт только `requirements.txt` и `app/`, но дампы БД из `backups/` каждый раз улетают в контекст сборки.

**`.gitignore`**:
```
backups/*.dump        # дампы БД не коммитим (там данные!)
load/results/*.json   # отчёты k6 не коммитим
```
💡 Сами папки сохраняются в git через пустые файлы `.gitkeep`: git не умеет хранить пустые каталоги.

---
## 2.4. `app/main.py` — всё приложение

Иду сверху вниз, блоками.

### Импорты
```python
import os                 # os.getenv — чтение переменных окружения
import time               # time.perf_counter — точный таймер для замера длительности

import psycopg            # драйвер Postgres
import redis              # клиент Redis
import string             # string.ascii_letters, string.digits — наборы символов
from fastapi import FastAPI, HTTPException, Response
from pydantic import BaseModel
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

app = FastAPI()           # объект приложения; к нему «прикручиваются» маршруты
```
⚠️ Файл сохранён в кодировке **cp1251**, а не UTF-8, поэтому комментарии на GitHub выглядят как `��������`. Python это переживает (комментарии не исполняются), но лучше перекодировать в UTF-8.
⚠️ `import secrets` стоит в середине файла (строка 112). Работает, но по PEP 8 все импорты должны быть наверху.

### Метрики
```python
REQUEST_COUNT = Counter(
    "http_requests_total",          # имя метрики в Prometheus
    "Total HTTP requests",          # описание (попадает в # HELP)
    ["method", "route", "status"],  # ЛЕЙБЛЫ: у каждой комбинации свой счётчик
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["method", "route"],
)
CACHE_HITS = Counter("cache_hits_total", "Total cache hits")
CACHE_MISSES = Counter("cache_misses_total", "Total cache misses")
```
Что это такое:
- **Counter** — число, которое только растёт (количество запросов). Prometheus потом считает скорость роста через `rate()`.
- **Histogram** — раскладывает длительности по «корзинам» (buckets): «сколько запросов было ≤ 5 мс, ≤ 10 мс, … ≤ 10 с». В `/metrics` это видно как `http_request_duration_seconds_bucket{le="0.25",...} 1234`, где `le` = «less or equal». По корзинам Prometheus вычисляет перцентили (p95).
- **Лейблы**: одна метрика превращается во множество временных рядов, например `http_requests_total{method="GET",route="/links/{code}",status="200"}`.

💡 Пример того, как выглядит `/metrics`:
```
# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total{method="GET",route="/links/{code}",status="200"} 5321.0
http_requests_total{method="POST",route="/links",status="201"} 402.0
cache_hits_total 4890.0
```

### Middleware — обёртка вокруг каждого запроса
```python
@app.middleware("http")                        # декоратор: зарегистрировать функцию как middleware
async def metrics_middleware(request, call_next):
    start = time.perf_counter()                # засекли время
    response = await call_next(request)        # передали запрос дальше (в роутер/эндпоинт) и ждём ответ
    duration = time.perf_counter() - start

    route = request.scope.get("route")         # объект маршрута, который FastAPI сопоставил с URL
    route = getattr(route, "path", request.url.path)
    #        ^ если маршрут найден — берём ШАБЛОН "/links/{code}",
    #          иначе (404 на неизвестный путь) — реальный путь запроса

    REQUEST_COUNT.labels(method=request.method, route=route, status=response.status_code).inc()
    REQUEST_LATENCY.labels(method=request.method, route=route).observe(duration)
    return response
```
Синтаксис:
- `@декоратор` над функцией = «передай эту функцию в декоратор». Здесь FastAPI запоминает её как middleware.
- `async def` / `await` — асинхронная функция. `await call_next(request)` = «подожди, пока остальная цепочка обработает запрос».
- `getattr(obj, "path", default)` = `obj.path`, а если атрибута нет (или `obj` = `None`) — `default`.

💡 **Почему шаблон маршрута, а не реальный путь.** Если писать `route="/links/aB3xY9k"`, у каждого кода был бы свой временной ряд, и Prometheus захлебнулся бы. Это называется «взрыв кардинальности».
⚠️ **Для несуществующих путей всё равно пишется реальный путь.** Бот, который сканирует `/wp-admin`, `/.env`, `/foo123`…, создаёт новые ряды. Лучше подставлять константу `"unmatched"`.
⚠️ **Важный баг: ошибки 500 не считаются.** Если внутри эндпоинта вылетает *необработанное* исключение (например, Redis недоступен → `redis.ConnectionError`), то `await call_next(request)` **пробрасывает исключение дальше**, и строки с `.inc()` / `.observe()` не выполняются. Ответ 500 формирует уже внешний слой Starlette. Итог: панель «HTTP 5xx Rate» в Grafana покажет ноль как раз тогда, когда всё горит. В метрики попадают только ошибки, выброшенные через `HTTPException` (404, 503, 500 «could not generate unique code»). Лечится `try/except/finally` вокруг `call_next`.

### Эндпоинт `/metrics`
```python
@app.get("/metrics")
def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)
```
`generate_latest()` собирает текст со всеми метриками процесса, `CONTENT_TYPE_LATEST` — правильный Content-Type (`text/plain; version=0.0.4`). `Response` отдаёт байты как есть, без превращения в JSON.
💡 Запросы к `/metrics` тоже проходят через middleware и считаются (`route="/metrics"`). Поэтому в дашборде стоит фильтр `route!="/metrics"`.

### Модель входных данных и конфиг
```python
class LinkCreate(BaseModel):
    url: str
```
Pydantic-модель. FastAPI видит `link: LinkCreate` в параметрах функции и сам: читает JSON-тело → проверяет, что есть поле `url` строкового типа → при ошибке отвечает **422** с описанием проблемы. Тебе не нужно писать ни строчки валидации.
⚠️ `str` принимает что угодно: `"abc"`, пустую строку, мегабайт текста. `pydantic.HttpUrl` проверял бы, что это URL.

```python
DATABASE_URL = os.getenv("DATABASE_URL")   # None, если переменной нет
REDIS_URL = os.getenv("REDIS_URL")
cache = redis.from_url(REDIS_URL)          # клиент Redis — ОДИН на весь процесс
```
💡 `redis.from_url` **ещё не подключается**. Соединение откроется при первой команде, а клиент держит пул соединений внутри.
⚠️ Если `REDIS_URL` не задан, приложение падает при импорте с малопонятной ошибкой.
⚠️ У клиента нет таймаутов (`socket_timeout`, `socket_connect_timeout`). Если Redis «завис», а не упал, запрос будет висеть очень долго.
⚠️ Нет `decode_responses=True`, поэтому Redis возвращает `bytes` и ниже приходится вручную вызывать `.decode()`.

### `/healthz` — liveness
```python
@app.get("/healthz")
def healthz():
    return {"status": "ok"}
```
Всегда 200, никуда не ходит. Смысл: «процесс жив и отвечает». Если бы он проверял БД, то при падении БД Docker/Kubernetes начал бы перезапускать *здоровый* api, получилась бы рестарт-петля.

### `/readyz` — readiness
```python
@app.get("/readyz")
def readyz():
    deps = {}                                            # словарь состояния зависимостей
    try:
        with psycopg.connect(DATABASE_URL, connect_timeout=2) as conn:
            conn.execute("SELECT 1")                     # простейший запрос «ты жив?»
        deps["db"] = "ok"
    except Exception as exc:
        deps["db"] = f"down: {exc.__class__.__name__}"   # f-строка: например "down: OperationalError"

    try:
        cache.ping()
        deps["cache"] = "ok"
    except Exception as exc:
        deps["cache"] = f"down: {exc.__class__.__name__}"

    if all(value == "ok" for value in deps.values()):    # all(...) — True, если ВСЕ элементы True
        return deps                                      # 200 {"db":"ok","cache":"ok"}
    raise HTTPException(status_code=503, detail=deps)    # 503 {"detail":{"db":"down: ...", ...}}
```
Синтаксис:
- `with ... as conn:` — **контекстный менеджер**. При выходе из блока соединение закрывается автоматически, даже если было исключение.
- `except Exception as exc` — поймать любую ошибку и положить её в `exc`. `exc.__class__.__name__` — имя класса ошибки.
- `value == "ok" for value in deps.values()` — генераторное выражение, «ленивый список» из True/False.
- `raise HTTPException(...)` — FastAPI превращает это в HTTP-ответ с нужным кодом.

💡 Смысл readiness: «можно ли слать мне трафик?». 200 — да, 503 — выведите меня из балансировки.
⚠️ В стеке `/readyz` пока никто не использует автоматически (ни healthcheck, ни балансировщик). Его дёргают только `verify.sh`, `smoke.js` и `setup()` в `slo.js`. Ценность появится на этапе 5 с Traefik.

### Генерация кода
```python
import secrets

def _generate_code(length: int = 7) -> str:            # аннотации типов: принимает int, возвращает str
    alphabet = string.ascii_letters + string.digits    # a-z A-Z 0-9 = 62 символа
    return "".join(secrets.choice(alphabet) for _ in range(length))
```
- `secrets.choice` — криптографически стойкий случайный выбор (в отличие от `random.choice`, коды нельзя предсказать).
- `for _ in range(7)` — повторить 7 раз, `_` = «переменная мне не нужна».
- `"".join(...)` — склеить символы в строку.
💡 62⁷ ≈ 3.5 триллиона вариантов, коллизии практически невозможны. `_` в начале имени функции = соглашение «внутренняя, не для внешнего использования».

### `POST /links` — создание
```python
@app.post("/links", status_code=201)                   # по умолчанию отвечать 201 Created
def create_link(link: LinkCreate):
    for _ in range(5):                                 # до 5 попыток
        code = _generate_code()
        try:
            with psycopg.connect(DATABASE_URL) as conn:
                conn.execute(
                    "INSERT INTO links (code, url) VALUES (%s, %s)",
                    (code, link.url),                  # параметры отдельно → нет SQL-инъекций
                )
            return {"code": code}
        except psycopg.errors.UniqueViolation:         # такой code уже есть (PRIMARY KEY)
            continue                                   # следующая попытка
    raise HTTPException(status_code=500, detail="could not generate unique code")
```
💡 **Почему нет `conn.commit()`.** В psycopg 3 `with psycopg.connect() as conn:` при *успешном* выходе из блока делает COMMIT, при исключении — ROLLBACK, и в любом случае закрывает соединение. Это важно понимать: без `with` вставка молча потерялась бы.
💡 **`%s` — не форматирование строк Python**, а плейсхолдер драйвера. Значения передаются в Postgres отдельно от текста запроса, поэтому `url = "'; DROP TABLE links; --"` безопасен.
⚠️ Здесь **нет `connect_timeout`** (в `readyz` и `get_link` он есть). При медленной или мёртвой БД запрос может висеть долго.
⚠️ **Новое TCP-соединение с Postgres на каждый запрос.** Это дорого: TCP-рукопожатие, стартовый пакет, аутентификация SCRAM (несколько обменов сообщениями), и только потом запрос. Под toxic с задержкой 300 мс на каждый ответный пакет одно подключение стоит уже порядка секунды. Правильное решение — пул соединений (`psycopg_pool.ConnectionPool`).

### `GET /links/{code}` — чтение
```python
@app.get("/links/{code}")                    # {code} — параметр пути
def get_link(code: str, response: Response): # response — объект, через который можно добавить заголовки
    cached = cache.get(code)                 # bytes или None
    if cached:
        CACHE_HITS.inc()
        response.headers["X-Cache"] = "HIT"
        if isinstance(cached, bytes):
            cached = cached.decode()         # bytes → str
        return {"url": cached, "source": "cache"}

    CACHE_MISSES.inc()
    with psycopg.connect(DATABASE_URL, connect_timeout=2) as conn:
        row = conn.execute("SELECT url FROM links WHERE code = %s", (code,)).fetchone()
        #                                                          ^ (code,) — кортеж из одного элемента, запятая обязательна!
    if row is None:
        raise HTTPException(status_code=404, detail="link not found")

    url = row[0]                             # fetchone() возвращает кортеж ("https://...",)
    cache.set(code, url, ex=60)              # положить в кэш на 60 секунд (ex = expire)
    response.headers["X-Cache"] = "MISS"
    return {"url": url, "source": "db"}
```
💡 `(code,)` vs `(code)`: без запятой скобки просто группируют выражение, и получится строка, а не кортеж.
💡 Заголовок `X-Cache` и поле `source` дублируют друг друга: k6 умеет читать любое из них.
⚠️ **Redis — жёсткая зависимость.** Если Redis недоступен, `cache.get` бросает исключение → 500, хотя данные есть в БД. Даже если БД уже ответила, падение `cache.set` превратит ответ в 500. Для сценария «мёртвый кэш» правильное поведение — ходить в БД напрямую (кэш как soft-dependency). Это ядро незаконченного этапа 4.
⚠️ **404 не кэшируются.** Запросы к несуществующим кодам каждый раз идут в БД.
⚠️ **Общее пространство ключей с `/hello`.** `/hello` кладёт в Redis ключ `"hello"`. Если потом запросить `GET /links/hello`, придёт `200 {"url": "Hello from API", "source": "cache"}` вместо 404. Настоящих кодов это не касается (у них 7 символов, у `hello` 5), но хорошая практика — префикс ключей: `link:{code}`.

### `/hello` — остаток первой версии
```python
@app.get("/hello")
def hello():
    cached = cache.get("hello")
    if cached:
        return {"source": "redis", "message": cached.decode()}
    message = "Hello from API"
    cache.set("hello", message, ex=60)
    return {"source": "generated", "message": message}
```
Это был первый «доказатель», что кэш работает. В контракт не входит, никем не используется, можно удалить.

### Общая картина по `main.py`
- Все эндпоинты — обычные `def`, не `async def`. FastAPI выполняет такие функции в **пуле потоков** (по умолчанию около 40 потоков). Это правильно, потому что psycopg и redis здесь синхронные: в `async def` они блокировали бы весь сервер. Но когда БД медленная, все 40 потоков могут зависнуть в ожидании, и новые запросы встанут в очередь.
- Итог: код короткий и читаемый, контракт выполнен. Слабые места: нет пула соединений, нет таймаутов у Redis, нет деградации при падении кэша, 5xx не попадают в метрики.

---

## 2.5. `migrations/001_init.sql`

```sql
CREATE TABLE IF NOT EXISTS links (             -- создать, только если таблицы ещё нет
    code TEXT PRIMARY KEY,                     -- код: уникален и индексирован автоматически
    url TEXT NOT NULL,                         -- url обязателен
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()  -- время создания с таймзоной, заполняется само
);
```
💡 `IF NOT EXISTS` делает миграцию **идемпотентной**: её можно запускать при каждом `up`, и повторный запуск ничего не сломает.
💡 `PRIMARY KEY` = `UNIQUE` + `NOT NULL` + индекс. Именно он даёт ошибку `UniqueViolation` при коллизии кода, и благодаря индексу `SELECT ... WHERE code = ...` быстрый.
⚠️ Нет таблицы учёта применённых миграций (как в alembic/flyway). С одной миграцией это не нужно, со второй-третьей начнёт мешать.

---
## 2.6. `prometheus/prometheus.yml`

```yaml
global:
  scrape_interval: 15s        # как часто забирать метрики со всех целей
  evaluation_interval: 15s    # как часто пересчитывать правила алертов

rule_files:
  - /etc/prometheus/rules/*.yml   # откуда брать правила (путь ВНУТРИ контейнера)

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager:9093   # куда отправлять сработавшие алерты

scrape_configs:
  - job_name: api               # имя джоба превращается в лейбл job="api" у всех метрик
    static_configs:
      - targets:
          - api:8080            # Prometheus сам идёт на http://api:8080/metrics
  - job_name: prometheus
    static_configs: [{targets: [localhost:9090]}]   # сам себя
  - job_name: cadvisor          # cadvisor:8080 — это порт ВНУТРИ сети, не 8081 хоста!
  - job_name: postgres          # postgres-exporter:9187
  - job_name: redis             # redis-exporter:9121
```
💡 **Pull-модель**: Prometheus сам ходит к сервисам за метриками, сервисы ничего никуда не шлют. Путь по умолчанию — `/metrics`.
💡 Проверить, что всё собирается: http://localhost:9090/targets, все цели должны быть `UP`.
💡 `rules/*.yml` работает, потому что вся папка `./prometheus` смонтирована в `/etc/prometheus`.

## 2.7. `prometheus/rules/api.yml` — алерт

```yaml
groups:
  - name: api-slo
    rules:
      - alert: APIReadP95High
        expr: |
          histogram_quantile(0.95,
            sum by (le) (
              rate(http_request_duration_seconds_bucket{job="api", method="GET", route="/links/{code}"}[5m])
            )
          ) > 0.3
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "API read p95 is above 300ms"
```
**Как читать PromQL изнутри наружу:**
1. `http_request_duration_seconds_bucket{...}` — счётчики корзин гистограммы только для чтений ссылок.
2. `rate(...[5m])` — скорость роста каждого счётчика в секунду, усреднённая за 5 минут.
3. `sum by (le) (...)` — сложить все ряды, сохранив только лейбл `le` (границу корзины). Нужно, если у api несколько экземпляров.
4. `histogram_quantile(0.95, ...)` — по корзинам вычислить 95-й перцентиль: время, быстрее которого выполнились 95% запросов.
5. `> 0.3` — больше 300 мс?

`for: 2m` — условие должно держаться 2 минуты подряд. До этого алерт в состоянии `pending`, потом `firing`.
💡 Порог 0.3 совпадает с SLO в `slo.js` (`P95_MS=300`). Алерт и нагрузочный тест говорят об одном и том же.
⚠️ Окно `[5m]` сглаживает: короткий всплеск на 30 секунд не поднимет алерт, а реальная реакция медленнее, чем «2 минуты».
⚠️ Это единственный алерт. Нет алертов на «api недоступен» (`up{job="api"} == 0`), рост 5xx, падение hit ratio.

## 2.8. `alertmanager/alertmanager.yml`
```yaml
route:
  receiver: default     # все алерты → получатель "default"
receivers:
  - name: default       # ...у которого НЕТ ни одного канала (email/webhook/telegram)
```
⚠️ Алерты доходят до Alertmanager (видно на http://localhost:9093) и **дальше никуда не уходят**. Для учебного стенда это допустимо, но стоит об этом помнить и записать в README.

## 2.9. Grafana provisioning

**`grafana/provisioning/datasources/datasource.yml`**
```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus              # постоянный ID — на него ссылается дашборд
    type: prometheus
    access: proxy                # запросы к Prometheus делает СЕРВЕР Grafana, а не твой браузер
    url: http://prometheus:9090  # поэтому можно использовать внутреннее имя
    isDefault: true
    editable: false              # в UI не редактируется
```
💡 `access: proxy` — ключевая деталь. Браузер не знает, что такое `prometheus:9090`, а контейнер Grafana знает.

**`grafana/provisioning/dashboards/dashboards.yml`**
```yaml
providers:
  - name: web-db-cache
    folder: Web DB Cache              # в какую папку положить в UI
    type: file
    updateIntervalSeconds: 10         # раз в 10 с перечитывать файлы
    allowUiUpdates: false             # правки из UI нельзя сохранить (источник правды — файл)
    options:
      path: /etc/grafana/dashboards   # откуда брать JSON (смонтировано из ./grafana/dashboards)
```

**`grafana/dashboards/web-db-cache.json`** — дашборд (JSON-экспорт из Grafana). Важные поля: `uid: "web-db-cache"`, `refresh: "10s"`, `time: now-1h`, и 4 панели:

| Панель | PromQL | Что значит |
|---|---|---|
| Request Rate (RPS) | `sum(rate(http_requests_total{route!="/metrics"}[5m]))` | запросов в секунду, без самих скрейпов |
| GET /links/{code} p95 | та же формула, что в алерте | задержка чтений |
| HTTP 5xx Rate | `sum(rate(http_requests_total{status=~"5..",route!="/metrics"}[5m]))` | `=~"5.."` — регулярка: 500–599 |
| Cache Hit Ratio | `hits / (hits + misses)` по `rate` | доля попаданий в кэш |

💡 Каждая панель ссылается на `"datasource": {"uid": "prometheus"}`. Поэтому `uid` в datasource.yml менять нельзя, иначе дашборд «потеряет» данные.
⚠️ Панель 5xx сейчас «слепая» к необработанным исключениям (см. middleware в §2.4).
⚠️ Метрики экспортёров и cAdvisor собираются, но на дашборде не показаны.

## 2.10. `toxiproxy/toxiproxy.json`
```json
[
  { "name": "db",    "listen": "0.0.0.0:15432", "upstream": "db:5432",    "enabled": true },
  { "name": "cache", "listen": "0.0.0.0:16379", "upstream": "cache:6379", "enabled": true }
]
```
Toxiproxy слушает `15432` и пересылает всё в `db:5432`, слушает `16379` и пересылает в `cache:6379`. В нормальном режиме это прозрачная труба. Командой `toxic add` в трубу добавляется «яд»:
- `latency` — задержка (`latency=300` мс);
- `reset_peer` — оборвать соединение (TCP RST);
- `timeout` — перестать передавать данные;
- `bandwidth` — ограничить скорость.
💡 Состояние toxic'ов хранится в памяти: после рестарта контейнера toxiproxy всё чисто.

## 2.11. `Makefile`

```make
.PHONY: smoke load chaos-db chaos-cache chaos-reset   # «цели не являются файлами»

prepare-load:
	mkdir -p load/results          # ВНИМАНИЕ: отступ в Makefile — это ТАБ, не пробелы
	chmod 0777 load/results        # k6 в контейнере работает от uid 12345, ему нужно право записи

smoke: prepare-load                # "smoke зависит от prepare-load": сначала выполнится она
	docker compose --profile load run --rm k6 run /scripts/smoke.js
load: prepare-load
	docker compose --profile load run --rm k6 run /scripts/slo.js
chaos-db: prepare-load
	./scripts/chaos.sh db-latency
chaos-cache: prepare-load
	./scripts/chaos.sh cache-down
chaos-reset:
	./scripts/chaos.sh reset
```
Синтаксис: `цель: зависимости`, строки ниже с табом — команды.
💡 `.PHONY` нужен, чтобы `make load` работал, даже если в папке есть файл или каталог с именем `load`. **А он есть: каталог `load/`!** Без `.PHONY` make решил бы, что «цель уже готова», и ничего не сделал бы. Так что `.PHONY` здесь не формальность.
⚠️ `prepare-load` не указан в `.PHONY` (некритично: файла с таким именем нет).
⚠️ Нет целей `up`, `down`, `verify`, `backup`, `restore`, `cycle`.
⚠️ `chmod 0777` — папка доступна на запись всем пользователям машины. Для локальной лабы допустимо.

## 2.12. `scripts/chaos.sh`

```bash
#!/usr/bin/env bash          # shebang: запускать через bash, найденный в PATH
set -euo pipefail            # «строгий режим»:
                             #  -e  выйти при первой ошибке любой команды
                             #  -u  ошибка при обращении к неопределённой переменной
                             #  -o pipefail  в пайпе a | b ошибка a не теряется

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
#   ${VAR:-default}  — взять $VAR, а если пусто — default
#   $(...)           — подставить вывод команды
#   BASH_SOURCE[0]   — путь к самому скрипту; dirname → его папка; /.. → корень проекта
cd "$PROJECT_DIR"            # чтобы docker compose нашёл compose.yaml, откуда бы ни запускали

usage() { cat <<EOF ... EOF }    # heredoc: многострочный текст до маркера EOF

toxiproxy() {                    # функция-обёртка
    docker compose exec -T toxiproxy /toxiproxy-cli "$@"
    # exec -T  — выполнить команду в работающем контейнере без TTY
    # "$@"     — все аргументы функции, каждый отдельным словом
}

run_slo() { docker compose --profile load run --rm k6 run /scripts/slo.js; }

reset() {
    toxiproxy toxic remove -n db_latency db 2>/dev/null || true
    toxiproxy toxic remove -n cache_reset cache 2>/dev/null || true
    # 2>/dev/null — скрыть ошибки; || true — не падать из-за set -e, если toxic'а и не было
}

db_latency() {
    reset                                            # начать с чистого состояния
    toxiproxy toxic add -t latency -n db_latency -a latency=300 db
    #                   тип       имя           атрибут          прокси
    trap reset EXIT      # при ЛЮБОМ выходе из скрипта (успех, ошибка, Ctrl+C) вызвать reset
    run_slo              # прогнать нагрузку под ядом
}

cache_down() { reset; toxiproxy toxic add -t reset_peer -n cache_reset cache; trap reset EXIT; run_slo; }

case "${1:-}" in                 # switch по первому аргументу
    db-latency) db_latency ;;
    cache-down) cache_down ;;
    reset) reset ;;
    -h|--help) usage ;;
    *) usage; exit 2 ;;          # * — всё остальное; exit 2 — «неправильное использование»
esac
```
💡 `trap reset EXIT` — очень правильная деталь: если k6 упадёт с кодом 99 (SLO нарушено), `set -e` завершит скрипт, но яд всё равно снимется.
⚠️ Файл в **cp1251**, поэтому сообщения `echo` в UTF-8-терминале превращаются в кракозябры.
⚠️ **Почему `cache-down` не работает как эксперимент.** Toxic добавляется ДО запуска k6. `slo.js` в `setup()` первым делом проверяет `/readyz`, а тот при оборванном Redis честно отвечает 503. k6 делает `fail()`, и нагрузка вообще не начинается. А если бы началась, все чтения вернули бы 500 (Redis — жёсткая зависимость, §2.4). Чтобы эксперимент имел смысл, нужно (1) включать toxic *после* старта нагрузки и (2) научить `get_link` жить без кэша.
🔎 **`db-latency`**: под задержкой 300 мс `setup()` засевает 200 ссылок последовательно, каждая — новое соединение через медленный прокси. Скорее всего, именно поэтому в `slo.js` пришлось поднять `setupTimeout` до 5 минут.

## 2.13. `scripts/db-backup-restore.sh`

Новые для тебя конструкции (остальное как в `chaos.sh`):
```bash
BACKUP_DIR="${BACKUP_DIR:-$PROJECT_DIR/backups}"

wait_for_db() {
    local i                                   # local — переменная видна только в функции
    for i in $(seq 1 60); do                  # 60 попыток
        if compose exec -T "$DB_SERVICE" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
            return 0                          # готово
        fi
        sleep 1
    done
    echo "PostgreSQL не стал готовым за 60 секунд" >&2   # >&2 — вывод в stderr
    return 1
}

backup() {
    backup_file="$BACKUP_DIR/${PG_DB}-$(date '+%Y-%m-%d_%H%M%S').dump"   # appdb-2026-09-26_153000.dump
    compose exec -T "$DB_SERVICE" pg_dump -U "$PG_USER" -d "$PG_DB" -Fc > "$backup_file"
    #  pg_dump работает ВНУТРИ контейнера и пишет в stdout,
    #  а "> файл" перенаправляет stdout уже на ХОСТЕ. -T обязателен: TTY испортил бы бинарные данные.
    #  -Fc — custom-формат: сжатый, восстанавливается через pg_restore, можно выборочно.
    test -s "$backup_file"                    # файл существует и НЕ пустой, иначе (set -e) выход с ошибкой
}

restore() {
    local backup_file="${1:-}"                # первый аргумент функции
    [[ -z "$backup_file" ]] && ...            # -z — строка пустая
    [[ ! -f "$backup_file" ]] && ...          # -f — это существующий файл
    compose exec -T "$DB_SERVICE" pg_restore --clean --if-exists --no-owner --no-privileges \
        -U "$PG_USER" -d "$PG_DB" < "$backup_file"
    #  < файл — подать файл с хоста на stdin процесса в контейнере
    #  --clean --if-exists — сначала DROP существующих объектов (без ошибки, если их нет)
    #  --no-owner --no-privileges — не пытаться восстановить владельцев и GRANT'ы
}
```
**`cycle`** — самопроверка, что бэкап настоящий:
1. поднять `db`, дождаться готовности;
2. `INSERT` тестовой строки с уникальным кодом `backup-restore-<unixtime>` (`ON CONFLICT ... DO UPDATE` — если такая есть, обновить);
3. сделать дамп;
4. **`docker compose down -v`** — удалить всё, включая тома;
5. поднять чистую `db`;
6. `pg_restore`;
7. `SELECT count(*)` тестовой строки: должно быть 1, иначе `exit 1`.

💡 Принцип: «бэкап, из которого не восстанавливались, — не бэкап». `cycle` это доказывает. Хорошая работа.
💡 `restored_count="${restored_count//[[:space:]]/}"` — `${var//шаблон/замена}` заменяет ВСЕ совпадения; здесь удаляются пробелы и переводы строк из вывода psql.
⚠️ **`down -v` сносит ВЕСЬ стек**, а не только БД: все контейнеры, тома `grafana_data`, `redis_data`. После `cycle` поднята только `db`, остальное нужно поднимать руками (`docker compose up -d`).
⚠️ Нет Make-целей для бэкапа, нет ротации старых дампов.
⚠️ После отдельного `restore` Redis может до 60 секунд отдавать старые данные по уже закэшированным кодам.

---
## 2.14. `checks/verify.sh` — приёмочные проверки

Автор — ревьюер (PR #2), ты его потом правил (коммит `3fa94eb`). Скрипт стоит понимать, потому что это «экзаменатор» проекта.

**Каркас:**
```bash
passed=0; failed=0; failed_names=()           # счётчики и массив имён проваленных проверок

ok()  { printf '  ✓ %s\n' "$1"; passed=$((passed + 1)); }       # $((...)) — арифметика
bad() { printf '  ✗ %s\n' "$1"; ...; failed=$((failed + 1)); failed_names+=("$1"); }  # += — добавить в массив

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || echo 000; }
#  -s тихо, -o /dev/null тело выбросить, -w напечатать только HTTP-код

trap restore_db EXIT      # если скрипт прервётся на середине, поднять db обратно
```
Шаблон каждой проверки: `[[ "$code" == "200" ]] && ok "имя" || bad "имя" "подсказка"`.

**Что проверяется по секциям:**
1. **Стек поднят.** Для каждого контейнера из `docker compose ps -q`: `running` и (`healthy` или без healthcheck).
2. **HTTP-контракт.** `/healthz` 200, `/readyz` 200, `/metrics` 200 и содержит `# TYPE`.
3. **Миграции.** В схеме `public` есть хотя бы одна таблица.
4. **Образы.** Нет `:latest` и образов без тега; собранный образ должен иметь тег.
5. **Эксплуатация.** У каждого контейнера есть лимит памяти, ротация логов (`max-size`), restart policy; `api` работает не от root; в `environment` нет секретов (регулярка ищет `password=…`, `secret=…`, `token=…` и `://user:pass@`).
6. **Негативная проверка (разрушающая).** `docker compose stop db` → `/readyz` должен дать **503**, а `/healthz` остаться **200** → `start db`.
7. **Персистентность.** Создать таблицу `verify_probe`, вставить строку, `restart db`, строка должна остаться, таблица удаляется.
В конце: при `failed > 0` — список провалов и `exit 1`.

`--quick` пропускает 6 и 7 (они останавливают БД).

⚠️ **Твоя правка про `migrate` — мёртвый код.** В `3fa94eb` ты добавил: если `name == "migrate"`, проверять `exited` и код 0; для `migrate` не требовать restart policy. Но это никогда не срабатывает, по двум причинам:
- `docker compose ps -q` **без `-a`** показывает только *работающие* контейнеры, а `migrate` уже завершился, его в списке нет;
- `docker inspect --format '{{.Name}}'` вернёт `web-db-cache-migrate-1`, а не `migrate`.

Правка ничего не ломает, но ничего и не проверяет. Плюс ревью просило прогонять `verify.sh` «без правок». Если хочешь проверять миграции, нужно `docker compose ps -a` и сравнение по имени *сервиса* (`--format '{{.Service}}'`).
⚠️ Секция 3 проверяет «есть хоть одна таблица», а не именно `links`. Если прошлый прогон прервался и оставил `verify_probe`, проверка пройдёт даже без миграций.
🔎 **Прогноз на текущем коде:** всё зелёное, кроме «секретов в environment нет»: пароль виден у `api`, `db`, `postgres-exporter`. То есть сейчас `verify.sh` → `exit 1`.

## 2.15. `load/smoke.js` — контрактный тест k6

JavaScript для k6 (это не Node.js: свои модули `k6/http`, `k6`).
```js
import http from 'k6/http';
import { check, fail } from 'k6';

const API = __ENV.API_URL || 'http://localhost:8080';   // __ENV — переменные окружения; || — значение по умолчанию

export const options = {
  vus: 1, iterations: 1,                  // 1 «виртуальный пользователь», 1 проход
  thresholds: { checks: ['rate==1.0'] },  // 100% проверок должны пройти, иначе exit 99
};

export default function () {              // тело теста; k6 вызывает его на каждой итерации
  const live = http.get(`${API}/healthz`);          // `...${}...` — шаблонная строка
  check(live, {
    'GET /healthz -> 200': (r) => r.status === 200,             // (r) => ... — стрелочная функция
    '/healthz не ходит в зависимости (< 50 ms)': (r) => r.timings.duration < 50,
  });
  // ... /readyz, /metrics (# TYPE и _duration_seconds_bucket)
  // POST /links → 201 + code; если нет — fail(): дальше проверять бессмысленно
  // GET дважды: первый MISS, второй HIT, url одинаковый
  // GET /links/zzzzzzzzzz → 404
}
```
💡 `check` **не останавливает** тест, а только отмечает «прошло / не прошло». Реальное «красное» даёт `thresholds`.
💡 Функция `cacheSource(res)` смотрит заголовок `X-Cache`, а если его нет — поле `source`. Поэтому API может реализовать любой из двух вариантов.

## 2.16. `load/slo.js` — нагрузочный SLO-тест

```js
const RPS = Number(__ENV.RPS || 50);      // все параметры можно переопределить через -e
const HOT_SHARE = 0.2, HOT_TRAFFIC = 0.8; // 80% запросов идут в 20% ключей

const cacheHits = new Rate('cache_hits');                 // своя метрика: доля true
const hitLatency = new Trend('read_latency_hit', true);   // своя метрика: распределение (true = это время)

export const options = {
  setupTimeout: '5m',            // ← добавлено тобой в a4ab2b1
  scenarios: {
    warmup: { executor: 'ramping-arrival-rate', exec: 'read', startRate: 1,
              stages: [{ target: RPS, duration: WARMUP }], preAllocatedVUs: 20, maxVUs: 300 },
    reads:  { executor: 'constant-arrival-rate', exec: 'read',  rate: RPS,       duration: DURATION, startTime: WARMUP, ... },
    writes: { executor: 'constant-arrival-rate', exec: 'write', rate: WRITE_RPS, duration: DURATION, startTime: WARMUP, ... },
  },
  thresholds: {
    'http_req_failed{endpoint:read}': ['rate<0.01'],                        // < 1% ошибок
    'http_req_duration{endpoint:read}': [`p(95)<${P95_MS}`, `p(99)<${P95_MS * 3}`],
    'http_req_duration{endpoint:write}': [`p(95)<${P95_MS * 2}`],
    cache_hits: [`rate>${HIT_RATIO}`],
    dropped_iterations: ['count<10'],
    ...
  },
};
```
Ключевые идеи:
- **Сценарии** идут параллельно по своему расписанию. `warmup` работает 0–30 с, `reads` и `writes` стартуют на 30-й секунде (`startTime: WARMUP`).
- **`arrival-rate` = открытая модель.** k6 запускает N запросов в секунду *независимо* от того, успевает ли сервис. Если сервис тормозит, k6 добавляет VU (до `maxVUs`). Если VU не хватает, итерации «роняются» (`dropped_iterations`).
- **Теги `{endpoint:read}`** позволяют ставить пороги отдельно на чтения и записи и не учитывать разогрев.
- **`setup()`** выполняется один раз до нагрузки: проверяет `/readyz`, засевает `SEED_LINKS=200` ссылок и возвращает `{codes}`. Этот объект передаётся в `read(data)`.
- **`read()`** выбирает код через `pickCode` (80/20), делает GET, в замерной фазе записывает HIT/MISS в `cache_hits` и время в `hitLatency`/`missLatency`.
- **`handleSummary()`** вызывается в конце: печатает человекочитаемый отчёт и пишет полный JSON в `/results/summary.json`, то есть в `load/results/summary.json` на хосте.
- Код выхода: `0` — все пороги выполнены, `99` — хотя бы один нарушен.

⚠️ `load/README.md` прямо говорит: «Сами скрипты менять не нужно… Если для прохождения теста хочется поправить тест — это сигнал, что проблема в сервисе». `setupTimeout: '5m'` — как раз такая правка. Настоящая причина — медленный засев (новое соединение на каждый запрос).

## 2.17. Документы и служебные файлы

- **`load/README.md`** — ТЗ на этап 4: контракт API, смысл открытой модели, разогрева, распределения 80/20, параметры, задания А–Г и критерий приёмки («smoke зелёный, slo зелёный на здоровом стенде и красный под хаосом, прогон одной командой, summary.json сохраняется»).
- **`REVIEW.md`** — ревью от 17.09 на коммит `51a22f9` (состояние ДО всех твоих правок): вердикт, таблица acceptance criteria, блокеры Б1–Б5, замечания К1–К14 и план из 5 этапов. Почти все твои коммиты — ответы на конкретные пункты отсюда (см. часть 3).
- **`test.md`** — тестовый файл для проверки PR-флоу, к проекту не относится.
- **`backups/.gitkeep`, `load/results/.gitkeep`** — пустые файлы, чтобы git хранил папки.
- **`ONBOARDING.md`** — мой документ из прошлого шага. Он закоммичен только локально в ветке `claude/cool-bell-ol5tsg`, на GitHub его нет.
- **`README.md`** проекта отсутствует (REVIEW Б5 требует).

---
# Часть 3. Твои правки: от «Add Prometheus metrics endpoint» до «[НЕ ДОДЕЛАНО]»

32 коммита за 19–26 сентября. Почти каждый закрывает конкретный пункт `REVIEW.md` (в скобках указан пункт). Я сгруппировал их по этапам, чтобы была видна логика, а не просто список.

## Точка старта (коммит `51a22f9`, до твоих правок)

Чтобы понимать, откуда ты пришёл:
- `main.py`: только `/healthz`, `/readyz` (отвечал **200 даже при мёртвой БД**, с телом `{"status":"not ready"}`) и `/hello`. Ни метрик, ни ссылок.
- Dockerfile: один этап, от root, без healthcheck, `pip install` без версий.
- compose: api ходил в `db`/`cache` напрямую; миграций не было; экспортёры без тега, лимитов и ротации логов; `restart` не стоял нигде; Prometheus ждал cAdvisor.
- Prometheus не скрейпил api и себя; Grafana настраивалась руками.

---

## Этап 1. «Честная база» (19–22.09)

### `c30a34d` Add Prometheus metrics endpoint (К9)
- **Что:** добавлен `@app.get("/metrics")` с `generate_latest()`, в `requirements.txt` добавлен `prometheus-client`.
- **Смысл:** `/metrics` перестал отвечать 404. Но своих метрик пока нет: отдаются только стандартные `process_*`/`python_*` (память, CPU, GC процесса).
- **Влияние:** Prometheus уже мог бы скрейпить api, но джоба ещё нет (появится в `99bd8ee`).

### `1202662` «# Одноразовый контейнер применяет схему до запуска API» (Б1)
- **Что:** сервис `migrate` + `migrations/001_init.sql`; у api `depends_on: db` заменён на `migrate: service_completed_successfully`.
- **Смысл:** впервые появилась таблица `links`. Api не стартует, пока схема не применена.
- **Замечания:** сообщение коммита начинается с `#`: похоже, в сообщение попал комментарий из файла. Без префикса `feat:`. В `psql` нет `ON_ERROR_STOP=1` (см. §2.1).

### `f50deac` Added relases & tags to Images (К1)
- **Что:** `image: web-db-cache:1.0.0` у api; теги `v0.20.1` и `v1.91.1` у экспортёров.
- **Смысл:** воспроизводимость: `latest` сегодня и через месяц — разные образы.

### `6b24e25` limit exporter's resources, `beeb4aa` limit docker log size and rotation (exporters) (К2)
- **Что:** `deploy.resources.limits` и `logging` у двух экспортёров.
- **Смысл:** теперь лимиты и ротация есть у всех сервисов (у остальных они были с самого начала).

### `dc55cd6` Add unless-stopped restart policy for containers (К3)
- **Что:** `restart: unless-stopped` у 8 долгоживущих сервисов.
- **Смысл:** стек переживает перезагрузку машины и падения.
- 💡 У `migrate` уже было `restart: "no"`, и это правильно: иначе init-контейнер перезапускался бы по кругу.

### `deb252a` Run api as non-root user (К5, часть 1)
- **Что:** `useradd --uid 10001 app`, `COPY --chown=app:app`, `USER app`.
- **Смысл:** процесс в контейнере больше не root.

### `9ac8617` Return 503 from /readyz when DB is unavailable (Б2, часть 1)
- **Что:** в `except` вместо `return {"status": "not ready"}` стало `raise HTTPException(503)`.
- **Смысл:** главный блокер ревью: readiness наконец «краснеет» кодом, а не только текстом.
- Ограничение на этот момент: БД только «подключилась», без `SELECT 1`; Redis не проверяется.

### `5f61a8a` fix: check database and redis readiness (Б2 + Б3)
- **Что:** `/readyz` переписан по образцу из REVIEW почти дословно: словарь `deps`, `SELECT 1` с `connect_timeout=2`, `cache.ping()`, 503 с перечнем состояний.
- **Смысл:** Redis — жёсткая зависимость, значит он должен быть в readiness.

### `8c96df6` fix: add link creation endpoint
- **Что:** `POST /links` и модель `LinkCreate(code: str, url: str)`: **клиент сам присылал код**, при дубле — **409 Conflict**.
- **Смысл:** первая «бизнес-логика».
- 💡 Это расходилось с контрактом k6: `smoke.js`/`slo.js` отправляют только `{"url": ...}` и ждут `code` в ответе. Поэтому потом пришлось переделывать (`5788e32`).

### `dd5af66` fix(api): add link read endpoint
- **Что:** `GET /links/{code}`: сначала Redis, при промахе Postgres, `SET` с TTL 60, заголовок `X-Cache`, 404.
- **Смысл:** появился паттерн cache-aside, ради которого проект и затевался.

### `93c2efa` fix(metrics): add application request and cache metrics (К9)
- **Что:** `Counter`/`Histogram`, `metrics_middleware`, `CACHE_HITS/MISSES.inc()` в `get_link`. Эндпоинт `/metrics` заменён на `app.mount("/metrics", make_asgi_app())` (как советовал REVIEW).
- **Смысл:** появились RPS, задержки и hit ratio, то есть можно ответить на вопрос «почему медленно».
- ⚠️ С этого момента живёт баг «5xx от исключений не считаются» (§2.4).

### `99bd8ee` fix(prometheus): scrape api and self (К9)
- **Что:** джобы `api` и `prometheus` в `prometheus.yml`.
- **Смысл:** метрики из предыдущего коммита начали реально собираться.

### `fab95d9` fix(prometheus): remove cAdvisor startup dependency (К8)
- **Что:** убран `depends_on: cadvisor` у Prometheus.
- **Смысл:** холодный старт стал быстрее на ~90 с (у cAdvisor `start_period: 90s`). Prometheus и так переживёт недоступную цель.

### `41a0905` fix(redis): configure memory eviction (К7)
- **Что:** `redis-server --maxmemory 200mb --maxmemory-policy allkeys-lru`.
- **Смысл:** под нагрузкой кэш вытесняет старые ключи, а не умирает по OOM.

### `f8a41dd` fix(security): harden api container (К5, часть 2)
- **Что:** `read_only`, `tmpfs /tmp`, `cap_drop: ALL`, `no-new-privileges`.

### `1478818` chore(compose): limit migration service
- **Что:** лимиты и логи для `migrate`, чтобы `verify.sh` не ругался.

### `36c2345` chore(deps): pin python dependencies (К13)
- **Что:** `==` версии в `requirements.txt`.
- 💡 REVIEW писал, что фактически ставилась `fastapi==0.141.1`, а ты запинил `0.136.1` (более старую). Наверное, взял версии из своего окружения. Не ошибка, просто стоит знать, откуда они.

### `1d27f4d` chore(docker): add dockerignore (К13)

### `027c614` build: refactor Dockerfile to multi-stage, add healthcheck… (К4, К13)
- **Что:** builder-этап с `pip wheel`, установка из колёс, `HEALTHCHECK` на `/healthz`.
- **Смысл:** у api появился статус `healthy`, значит на него можно навесить `depends_on: service_healthy` (так и сделал k6 позже).
- ⚠️ Реальной экономии размера нет: слой `/wheels` остаётся в образе (§2.2).

### `3fa94eb` fix: update verify checks and add app metrics
Два изменения в одном коммите:
1. **`main.py`:** откат `app.mount("/metrics", make_asgi_app())` обратно на `@app.get("/metrics")`.
   🔎 Почти наверняка причина такая: `Mount("/metrics")` в Starlette отвечает на `/metrics` **редиректом 307 на `/metrics/`**. `verify.sh` использует `curl` без `-L` (не ходит по редиректам), получает 307 и считает проверку проваленной. Возврат к обычному маршруту — нормальное решение. Стоит запомнить, почему mount так себя ведёт.
2. **`verify.sh`:** особая обработка `migrate`. ⚠️ Это мёртвый код (§2.14). Название коммита «add app metrics» вводит в заблуждение: метрики добавлены раньше, здесь изменён только способ отдачи.

**Итог этапа 1:** закрыто почти всё из REVIEW, кроме секретов (К6), портов на 0.0.0.0 (К11), пула соединений и таймаутов (К12), cAdvisor (К14) и битого комментария.

---

## Этап 2. Наблюдаемость как код (23–26.09)

### `e22fb27` feat(grafana): provision prometheus datasource (К10)
- datasource из файла, `uid: prometheus`. После `down -v` Grafana сама знает, куда ходить.

### `d1c39d3` feat(grafana): provision web db cache dashboard (К10)
- Провайдер дашбордов + JSON с 4 панелями. Дашборд стал частью репозитория.

### `383b7f0` feat(alertmanager): add alertmanager service
- Сервис + минимальный конфиг. ⚠️ Receiver без каналов.

### `5b8dda4` feat(prometheus): add api latency alerting
- `rule_files`, `alerting`, правило `APIReadP95High` (p95 > 300 мс в течение 2 минут). Ровно то, что требовал этап 2 REVIEW.

---

## Этап 3. Backup/restore (26.09)

### `a266f42` chore(backup): add backup storage directory
- `backups/.gitkeep` + `.gitignore: backups/*.dump`: папка в git есть, дампов нет.

### `06c67bd` и `e212fbe` feat(backup): add postgres backup and restore script (дважды)
- Первый коммит — **пустой** исполняемый файл (видимо, `touch` + `chmod +x` + коммит), второй — содержимое, 209 строк.
- ⚠️ В `e212fbe` файл был в cp1251. В `5788e32` он перекодирован в UTF-8 (весь дифф в том коммите — только кодировка). Лучше делать такое отдельным коммитом `chore: convert to utf-8`.

---

## Этап 4. Нагрузка и хаос (26.09)

### `5788e32` fix(api): generate link code server-side per load contract
Самый «смешанный» коммит, в нём пять разных изменений:
1. **`main.py`:** `LinkCreate` потерял поле `code`; появилась `_generate_code()` (`secrets.choice`, 7 символов); `create_link` делает до 5 попыток при `UniqueViolation`, иначе 500. 409 больше нет. **Это то, что заявлено в сообщении.**
2. **`compose.yaml`:** добавлен сервис `k6` под профилем `load`. Это отдельная фича (задание В из `load/README.md`).
3. **`.gitignore`:** `load/results/*.json` + `load/results/.gitkeep`.
4. **`db-backup-restore.sh`:** перекодирован в UTF-8.
5. ⚠️ **`main.py` при этом сохранён в cp1251**: новые русские комментарии стали кракозябрами на GitHub.
- 💡 Похоже, твой редактор на Windows по умолчанию сохраняет в cp1251. Один файл ты починил, другой в том же коммите сломал. Стоит проверить настройку кодировки редактора (UTF-8 по умолчанию) и добавить `.editorconfig` с `charset = utf-8`.
- ⚠️ Сообщение описывает 1 изменение из 5. Для ревьюера это неприятно: `git log` врёт о содержимом. Правило из REVIEW: «одна тема на коммит».

### `3bf79c6` feat(load): add k6 make targets
- `Makefile` с `smoke`, `load`, `chaos-*`. Цели `chaos-*` ссылаются на `scripts/chaos.sh`, **которого на этом коммите ещё нет**: он появится только в `a4ab2b1`. Не баг, но коммит сам по себе не «рабочий».

### `cf10908` feat(chaos): route api dependencies through toxiproxy
- Сервис `toxiproxy`, `toxiproxy.json`; `DATABASE_URL`/`REDIS_URL` у api переключены на `toxiproxy:15432`/`toxiproxy:16379`; api ждёт `toxiproxy: service_healthy`.
- **Смысл:** с этого момента весь трафик api к зависимостям идёт через управляемую «трубу» (задание Г).
- ⚠️ 🔎 Проблема с `-host` и портом 8474 (§2.1).

### `a4ab2b1` [НЕ ДОДЕЛАНО] feat(chaos): add database latency and cache failure scenarios
- `scripts/chaos.sh` (cp1251) с `db-latency`, `cache-down`, `reset`; в `slo.js` добавлен `setupTimeout: '5m'`.
- **Что не доделано по факту** (мой разбор, §2.12):
  1. `cache-down` падает в `setup()` на `/readyz`, эксперимент не начинается;
  2. даже если начнётся, api без Redis отдаёт 500, то есть «деградация» = отказ;
  3. 500 не попадают в метрики, дашборд этого не покажет;
  4. правка `slo.js` противоречит правилу «тесты не трогать»;
  5. нет записанных прогонов (`summary.json`) и выводов в `answers.md`.

---

## Сквозные наблюдения по истории

- **Хорошее:** ты систематически прошёл по REVIEW пункт за пунктом. Семантические префиксы (`fix:`, `feat:`, `chore:`) появились с 21.09 и держатся. Коммиты этапа 1 маленькие и атомарные. Есть проверенный цикл backup → restore.
- **Повторяющиеся проблемы:**
  1. кодировка cp1251 (`main.py`, `chaos.sh`, раньше `db-backup-restore.sh`, комментарий в compose);
  2. «сборные» коммиты с неполным сообщением (`3fa94eb`, `5788e32`);
  3. правки в чужих «экзаменаторах» (`verify.sh`, `slo.js`) вместо правок сервиса;
  4. пустой коммит-заготовка (`06c67bd`).
- **Код, который выглядит «списанным»:** `/readyz` почти дословно совпадает с образцом из REVIEW. Это нормально, но проверь, что понимаешь каждую строку (часть 5 поможет).

---

# Часть 4. Важные замечания (без правок, по приоритету)

**Важно для смысла проекта (этап 4):**
1. `get_link` без Redis отдаёт 500. Нужен fallback на БД + таймауты Redis-клиента, иначе сценарий «мёртвый кэш» бессмысленен.
2. `metrics_middleware` не видит 500 от исключений, поэтому дашборд врёт во время аварий.
3. `chaos.sh cache-down` ломает кэш до `setup()`, и тест падает, не начавшись.
4. Новое соединение с Postgres на каждый запрос. Это причина медленного засева и `setupTimeout: 5m`; лечится пулом соединений.

**Важно для корректности:**
5. `migrate`: `psql` без `-v ON_ERROR_STOP=1` — ошибка миграции не остановит старт api.
6. `verify.sh`: правки про `migrate` не срабатывают (`ps` без `-a`, имя контейнера ≠ имя сервиса).
7. `verify.sh` на текущем коде должен быть красным из-за паролей в `environment`.
8. `cycle` в бэкап-скрипте делает `down -v` всего стека.

**Безопасность (если стенд окажется не только на localhost):**
9. Grafana `admin/admin`, Prometheus, Alertmanager, cAdvisor на `0.0.0.0`.
10. Пароль БД в compose открытым текстом в 4 местах.

**Гигиена:**
11. Кодировка cp1251 → UTF-8 + `.editorconfig`.
12. Удалить `/hello` и `test.md`; префикс ключей Redis (`link:`).
13. Makefile: `up/down/verify/backup/restore`; README проекта.
14. 🔎 Проверить, работает ли `curl localhost:8474` с хоста (вопрос `-host=0.0.0.0`); в любом случае порт 8474 наружу не нужен.

---

# Часть 5. Проверь себя

Отвечай сам, потом открывай ответ. Если на 80% отвечаешь без подсказки, проект снова твой.

<details><summary>1. Почему у <code>db</code> и <code>cache</code> нет <code>ports</code>, и как тогда api к ним подключается?</summary>
Порты нужны только для доступа с хоста. Контейнеры в одной compose-сети видят друг друга по имени сервиса (DNS) на внутренних портах. api ходит на <code>toxiproxy:15432</code>, а toxiproxy — на <code>db:5432</code>.
</details>

<details><summary>2. Чем <code>/healthz</code> отличается от <code>/readyz</code>, и что сломается, если в <code>/healthz</code> добавить проверку БД?</summary>
Liveness («процесс жив») против readiness («готов принимать трафик»). Если liveness зависит от БД, то при падении БД оркестратор начнёт перезапускать здоровые api — получится рестарт-петля, и после возврата БД все api будут в процессе рестарта.
</details>

<details><summary>3. Почему в <code>create_link</code> нет <code>conn.commit()</code>, но данные сохраняются?</summary>
<code>with psycopg.connect() as conn:</code> в psycopg 3 делает COMMIT при нормальном выходе из блока и ROLLBACK при исключении.
</details>

<details><summary>4. Что будет с ответом <code>GET /links/{code}</code>, если Redis упал? А если упала только БД, но код есть в кэше?</summary>
Redis упал → <code>cache.get</code> бросает исключение → 500 (и оно не попадает в метрики). Упала БД, но код в кэше → 200 из кэша: БД вообще не трогается.
</details>

<details><summary>5. Зачем в метрике лейбл <code>route="/links/{code}"</code>, а не реальный путь?</summary>
Чтобы не было «взрыва кардинальности»: иначе каждый код создавал бы новый временной ряд.
</details>

<details><summary>6. Разбери <code>histogram_quantile(0.95, sum by (le) (rate(..._bucket[5m])))</code> по шагам.</summary>
Корзины гистограммы → скорость роста за 5 минут → сумма по экземплярам с сохранением границы корзины <code>le</code> → 95-й перцентиль по корзинам.
</details>

<details><summary>7. Почему <code>migrate</code> имеет <code>restart: "no"</code>, а api ждёт <code>service_completed_successfully</code>, а не <code>service_healthy</code>?</summary>
migrate — одноразовая задача: сделал и вышел. Healthy у него не бывает; важен код выхода 0. С <code>restart: unless-stopped</code> он перезапускался бы бесконечно.
</details>

<details><summary>8. Что делает <code>trap reset EXIT</code> в <code>chaos.sh</code> и зачем он там?</summary>
Вызывает <code>reset</code> при любом завершении скрипта. k6 при нарушении SLO выходит с кодом 99, <code>set -e</code> прерывает скрипт, но toxic всё равно снимается, и стенд не остаётся «отравленным».
</details>

<details><summary>9. Почему <code>make load</code> работает только благодаря <code>.PHONY</code>?</summary>
В проекте есть каталог <code>load/</code>. Без <code>.PHONY</code> make считал бы цель <code>load</code> уже «собранной» и ничего не запускал.
</details>

<details><summary>10. Что такое открытая модель нагрузки и почему <code>dropped_iterations</code> — это порог?</summary>
k6 подаёт N запросов в секунду независимо от скорости ответов (как реальные пользователи). Если VU не хватило, итерации роняются, реальная нагрузка оказывается меньше заявленной, и все остальные цифры относятся уже к другому эксперименту.
</details>

<details><summary>11. Почему <code>cache-down</code> сейчас не даёт осмысленного результата? Назови 3 причины.</summary>
(1) toxic ставится до <code>setup()</code>, а <code>/readyz</code> → 503 → <code>fail</code>; (2) без Redis api отдаёт 500 вместо чтения из БД; (3) эти 500 не видны в метриках.
</details>

<details><summary>12. Почему твоя проверка <code>migrate</code> в <code>verify.sh</code> никогда не срабатывает?</summary>
<code>docker compose ps -q</code> без <code>-a</code> не показывает завершённые контейнеры, а имя контейнера — <code>web-db-cache-migrate-1</code>, а не <code>migrate</code>.
</details>

<details><summary>13. Зачем в бэкапе <code>exec -T</code>, и где выполняется <code>&gt; "$backup_file"</code>?</summary>
<code>-T</code> отключает псевдотерминал, который испортил бы бинарный поток дампа. Перенаправление <code>&gt;</code> выполняет твой bash на хосте, поэтому файл оказывается в <code>./backups</code> на хосте.
</details>

<details><summary>14. Почему Grafana-datasource использует <code>access: proxy</code>, и что будет, если поменять <code>uid</code>?</summary>
Запросы делает сервер Grafana, которому доступно имя <code>prometheus</code> в сети; браузеру оно недоступно. Если поменять <code>uid</code>, панели дашборда перестанут находить источник данных.
</details>

## Практика «сломай и посмотри» (самый быстрый способ вернуть проект в голову)

1. `docker compose up -d`, затем `docker compose ps -a`: найди `migrate` в статусе `Exited (0)`.
2. `curl -i localhost:8080/readyz` → `docker compose stop cache` → снова `curl`. Посмотри тело 503. `docker compose start cache`.
3. `curl -X POST localhost:8080/links -H 'Content-Type: application/json' -d '{"url":"https://example.org"}'` → дважды `curl -i localhost:8080/links/<code>`: найди заголовок `X-Cache`.
4. `curl -s localhost:8080/metrics | grep -E 'http_requests_total|cache_'`: найди свои запросы.
5. `docker compose stop cache` → `curl localhost:8080/links/<code>` (500) → `curl -s localhost:8080/metrics | grep 'status="500"'`. Если пусто, ты своими глазами увидел баг middleware.
6. В `001_init.sql` временно допиши `SELECT 1/0;` → `docker compose up -d migrate` → `docker compose ps -a`: будет `Exited (0)`, хотя SQL упал. Это баг `ON_ERROR_STOP`. Верни файл.
7. `make smoke` → `make load` → открой `load/results/summary.json`, найди `metrics.cache_hits.values.rate` и `metrics["http_req_duration{endpoint:read}"].values["p(95)"]`.
8. `make chaos-db` и одновременно открой Grafana (http://localhost:3000, папка «Web DB Cache»): что происходит с p95 и hit ratio?
9. `curl localhost:8474/proxies` с хоста: проверь мою догадку про `-host`.
