import os

import psycopg
import redis
from fastapi import FastAPI

app = FastAPI()

DATABASE_URL = os.getenv("DATABASE_URL")
REDIS_URL = os.getenv("REDIS_URL")

cache = redis.from_url(REDIS_URL)


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/readyz")
def readyz():
    try:
        with psycopg.connect(DATABASE_URL):
            return {"status": "ready"}
    except Exception:
        return {"status": "not ready"}


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
