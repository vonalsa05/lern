#!/bin/sh

set -eu

CONTAINER=$(docker compose ps -q api)
IMAGE="security-app:1.0.0"

echo "== Security verification =="

fail=0

check() {
    name="$1"
    condition="$2"

    if [ "$condition" = "true" ]; then
        echo "PASS: $name"
    else
        echo "FAIL: $name"
        fail=1
    fi
}

# 1. Container exists
if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    check "container exists" true
else
    check "container exists" false
    exit 1
fi

# 2. Non-root
USER=$(docker inspect "$CONTAINER" \
    --format '{{.Config.User}}')

check "non-root user is app" \
    "$( [ "$USER" = "app" ] && echo true || echo false )"

# 3. Read-only root filesystem
READONLY=$(docker inspect "$CONTAINER" \
    --format '{{.HostConfig.ReadonlyRootfs}}')

check "read-only rootfs" \
    "$( [ "$READONLY" = "true" ] && echo true || echo false )"

# 4. Drop all capabilities
CAP_DROP=$(docker inspect "$CONTAINER" \
    --format '{{range .HostConfig.CapDrop}}{{println .}}{{end}}')

check "all capabilities dropped" \
    "$( [ "$CAP_DROP" = 'ALL' ] && echo true || echo false )"

# 5. no-new-privileges
SECURITY_OPT=$(docker inspect "$CONTAINER" \
    --format '{{json .HostConfig.SecurityOpt}}')

check "no-new-privileges" \
    "$( echo "$SECURITY_OPT" | grep -q 'no-new-privileges:true' && echo true || echo false )"


MEM_LIMIT=$(docker inspect "$CONTAINER" \
    --format '{{.HostConfig.Memory}}')

check "memory limit is set" \
    "$( [ "$MEM_LIMIT" -gt 0 ] && echo true || echo false )"

CPU_LIMIT=$(docker inspect "$CONTAINER" \
    --format '{{.HostConfig.NanoCpus}}')

check "CPU limit is set" \
    "$( [ "$CPU_LIMIT" -gt 0 ] && echo true || echo false )"

# 6. No secrets in environment
ENV=$(docker inspect "$CONTAINER" \
    --format '{{range .Config.Env}}{{println .}}{{end}}')

if echo "$ENV" | grep -qiE 'password|token|secret|api_key|private_key'; then
    check "no secrets in environment" false
else
    check "no secrets in environment" true
fi

# 7. Image must not use latest
if echo "$IMAGE" | grep -q ':latest$'; then
    check "image does not use latest" false
else
    check "image does not use latest" true
fi

# 8. Healthcheck
HEALTH=$(docker inspect "$CONTAINER" \
    --format '{{.State.Health.Status}}')

check "container is healthy" \
    "$( [ "$HEALTH" = "healthy" ] && echo true || echo false )"

echo


echo
echo "== Trivy scan =="

if docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$HOME/.cache/trivy:/root/.cache/trivy" \
    aquasec/trivy:latest \
    image \
    --severity HIGH,CRITICAL \
    --exit-code 1 \
    "$IMAGE" >/tmp/trivy.log 2>&1
then
    echo "PASS: no HIGH/CRITICAL vulnerabilities"
else
    echo "FAIL: HIGH/CRITICAL vulnerabilities found"
    cat /tmp/trivy.log
    fail=1
fi


if [ "$fail" -eq 0 ]; then
    echo "ALL CHECKS PASSED"
    exit 0
else
    echo "SOME CHECKS FAILED"
    exit 1
fi
