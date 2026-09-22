FROM python:3.12-slim AS builder

WORKDIR /build

COPY requirements.txt .

RUN pip wheel \
    --no-cache-dir \
    --wheel-dir /wheels \
    -r requirements.txt


FROM python:3.12-slim

WORKDIR /app

RUN useradd --create-home --uid 10001 app

COPY requirements.txt .
COPY --from=builder /wheels /wheels

RUN pip install \
    --no-cache-dir \
    --no-index \
    --find-links=/wheels \
    -r requirements.txt \
    && rm -rf /wheels

COPY --chown=app:app app/ ./app/

USER app

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=5s --retries=5 \
    CMD python -c \
    "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz')" \
    || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]