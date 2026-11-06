#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?Usage: ./scripts/pipeline.sh IMAGE}"
KEY="${PROD_API_KEY:-lab-secret}"
GATE_URL="http://localhost:4174"
PROD_URL="http://localhost:4173"

cleanup_gate() {
  docker rm -f citybike-gate >/dev/null 2>&1 || true
}

wait_for_health() {
  local url="$1"
  for attempt in $(seq 1 30); do
    if curl -fsS "$url/health" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "ERROR: Health check timed out: $url" >&2
  return 1
}

trap cleanup_gate EXIT

for gate in staging uat oat preprod; do
  echo "=== Gate: $gate ==="
  cleanup_gate

  if [[ "$gate" == "preprod" ]]; then
    docker run -d --name citybike-gate \
      -p 4174:4173 \
      -e APP_ENV="$gate" \
      -e PROD_API_KEY="$KEY" \
      "$IMAGE"
  else
    docker run -d --name citybike-gate \
      -p 4174:4173 \
      -e APP_ENV="$gate" \
      "$IMAGE"
  fi

  wait_for_health "$GATE_URL"

  TARGET_URL="$GATE_URL" IMAGE_NAME="$IMAGE" \
    bash "scripts/test-$gate.sh"

  cleanup_gate
  echo "PASS: $gate"
done

echo "=== Gate: production ==="

# Do not replace an existing production service until
# every pre-production gate has passed.
docker rm -f citybike-prod >/dev/null 2>&1 || true

docker run -d --name citybike-prod \
  -p 4173:4173 \
  -e APP_ENV=production \
  -e PROD_API_KEY="$KEY" \
  "$IMAGE"

wait_for_health "$PROD_URL"

if TARGET_URL="$PROD_URL" bash scripts/test-prod.sh; then
  echo "PASS: production"
  echo "SUCCESS: All five gates passed."
else
  docker rm -f citybike-prod >/dev/null 2>&1 || true
  echo "FAIL: Production gate" >&2
  exit 1
fi
