import os

import psycopg
import redis
from fastapi import FastAPI, HTTPException, Response
from pydantic import BaseModel
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

app = FastAPI()


class LinkCreate(BaseModel):
    code: str
    url: str

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


@app.post("/links", status_code=201)
def create_link(link: LinkCreate):
    try:
        with psycopg.connect(DATABASE_URL) as conn:
            conn.execute(
                """
                INSERT INTO links (code, url)
                VALUES (%s, %s)
                """,
                (link.code, link.url),
            )

        return {"code": link.code}

    except psycopg.errors.UniqueViolation:
        raise HTTPException(
            status_code=409,
            detail="link code already exists",
        )

@app.get("/links/{code}")
def get_link(code: str, response: Response):
    cached = cache.get(code)

    if cached:
        response.headers["X-Cache"] = "HIT"

        if isinstance(cached, bytes):
            cached = cached.decode()

        return {
            "url": cached,
            "source": "cache",
        }

    with psycopg.connect(
        DATABASE_URL,
        connect_timeout=2,
    ) as conn:
        row = conn.execute(
            "SELECT url FROM links WHERE code = %s",
            (code,),
        ).fetchone()

    if row is None:
        raise HTTPException(
            status_code=404,
            detail="link not found",
        )

    url = row[0]

    cache.set(code, url, ex=60)

    response.headers["X-Cache"] = "MISS"

    return {
        "url": url,
        "source": "db",
    }

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