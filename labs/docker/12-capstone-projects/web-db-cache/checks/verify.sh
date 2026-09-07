#!/usr/bin/env bash

set -e

echo "== Checking containers =="

docker compose ps

echo
echo "== Checking API /healthz =="

curl -fsS http://localhost:8080/healthz

echo
echo "== Checking API /readyz =="

curl -fsS http://localhost:8080/readyz

echo
echo "== Checking API /hello =="

curl -fsS http://localhost:8080/hello

echo
echo "== Checking Prometheus =="

curl -fsS http://localhost:9090/-/healthy

echo
echo "== Checking cAdvisor =="

curl -fsS http://localhost:8081/healthz

echo
echo "== All checks passed =="
