import os

import psycopg
import redis
from fastapi import FastAPI, HTTPException, Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

app = FastAPI()


@app.get("/metrics")
def metrics():
    return Response(
        content=generate_latest(),
        media_type=CONTENT_TYPE_LATEST,
    )

DATABASE_URL = os.getenv("DATABASE_URL")
REDIS_URL = os.getenv("REDIS_URL")

cache = redis.from_url(REDIS_URL)


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/readyz")
def readyz():
    deps = {}

    try:
        with psycopg.connect(
            DATABASE_URL,
            connect_timeout=2,
        ) as conn:
            conn.execute("SELECT 1")

        deps["db"] = "ok"

    except Exception as exc:
        deps["db"] = f"down: {exc.__class__.__name__}"

    try:
        cache.ping()
        deps["cache"] = "ok"

    except Exception as exc:
        deps["cache"] = f"down: {exc.__class__.__name__}"

    if all(value == "ok" for value in deps.values()):
        return deps

    raise HTTPException(
        status_code=503,
        detail=deps,
    )


@app.get("/hello")
def hello():
    cached = cache.get("hello")

    if cached:
        return {
            "source": "redis",
            "message": cached.decode()
        }

    message = "Hello from API"

    cache.set("hello", message, ex=60)

    return {
        "source": "generated",
        "message": message
    }