#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="v1.0.0"

#######################################
# REQUIRED: Digest pinned image
#######################################
IMAGE="${OPENCLAW_IMAGE:-}"
if [[ -z "$IMAGE" ]]; then
  echo "ERROR: OPENCLAW_IMAGE must be set (name@sha256:...)" >&2
  exit 1
fi
if [[ ! "$IMAGE" =~ @sha256:[a-fA-F0-9]{64}$ ]]; then
  echo "ERROR: Image must be digest pinned (name@sha256:...)" >&2
  exit 1
fi

#######################################
# Runtime Configuration
#######################################
CONTAINER_NAME="openclaw"
CANDIDATE_NAME="openclaw_candidate"

CPU_LIMIT="${OPENCLAW_CPUS:-1.0}"
MEM_LIMIT="${OPENCLAW_MEMORY:-1g}"

HOST_PORT="${OPENCLAW_HOST_PORT:-8080}"
CONTAINER_PORT="${OPENCLAW_CONTAINER_PORT:-8080}"

ENV_FILE="${OPENCLAW_ENV_FILE:-}"
NETWORK="${OPENCLAW_NETWORK:-}"
HEALTH_TIMEOUT="${OPENCLAW_HEALTH_TIMEOUT_SEC:-180}"
HEALTH_POLL="${OPENCLAW_HEALTH_POLL_SEC:-3}"

LOG_MAX_SIZE="${OPENCLAW_LOG_MAX_SIZE:-10m}"
LOG_MAX_FILE="${OPENCLAW_LOG_MAX_FILE:-5}"

PLATFORM="linux/arm64"

LOCK_FILE="/var/run/openclaw.deploy.lock"

#######################################
# Helpers
#######################################
log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

docker_ready() {
  docker info >/dev/null 2>&1 || fail "Docker daemon not reachable"
}

container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

container_health() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || true
}

#######################################
# Spec Hash (Idempotency)
#######################################
compute_env_sha() {
  if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
    sha256sum "$ENV_FILE" | awk '{print $1}'
  else
    echo "none"
  fi
}

compute_spec_hash() {
  {
    echo "image=$IMAGE"
    echo "cpus=$CPU_LIMIT"
    echo "memory=$MEM_LIMIT"
    echo "host_port=$HOST_PORT"
    echo "container_port=$CONTAINER_PORT"
    echo "env_sha=$(compute_env_sha)"
    echo "network=$NETWORK"
    echo "log_size=$LOG_MAX_SIZE"
    echo "log_file=$LOG_MAX_FILE"
  } | sha256sum | awk '{print $1}'
}

#######################################
# Health Wait
#######################################
wait_for_healthy() {
  local name="$1"
  local timeout="$2"
  local poll="$3"
  local elapsed=0

  while (( elapsed <= timeout )); do
    local running health
    running="$(container_running "$name" && echo true || echo false)"
    health="$(container_health "$name")"

    if [[ "$running" != "true" ]]; then
      log "Container stopped unexpectedly"
      docker logs --tail 200 "$name" || true
      return 1
    fi

    if [[ "$health" == "healthy" || "$health" == "none" ]]; then
      return 0
    fi

    if [[ "$health" == "unhealthy" ]]; then
      log "Container reported unhealthy"
      docker logs --tail 200 "$name" || true
      return 1
    fi

    sleep "$poll"
    (( elapsed += poll ))
  done

  log "Health timeout exceeded"
  docker logs --tail 200 "$name" || true
  return 1
}

#######################################
# Main
#######################################
main() {

  exec 9>"$LOCK_FILE"
  flock -n 9 || fail "Another deployment running"

  require_cmd docker
  require_cmd sha256sum
  docker_ready

  SPEC_HASH="$(compute_spec_hash)"

  log "Starting deploy ${VERSION}"
  log "Spec hash: $SPEC_HASH"

  ###################################
  # Drift Detection
  ###################################
  if container_exists "$CONTAINER_NAME"; then
    CURRENT_HASH="$(docker inspect -f '{{ index .Config.Labels "com.openclaw.spec-hash" }}' "$CONTAINER_NAME" 2>/dev/null || true)"
    CURRENT_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    CURRENT_HEALTH="$(container_health "$CONTAINER_NAME")"

    if [[ "$CURRENT_HASH" == "$SPEC_HASH" && "$CURRENT_IMAGE" == "$IMAGE" ]]; then
      if container_running "$CONTAINER_NAME" && [[ "$CURRENT_HEALTH" == "healthy" || "$CURRENT_HEALTH" == "none" ]]; then
        log "No drift detected. Skipping."
        exit 0
      fi
    fi
  fi

  ###################################
  # Pull image
  ###################################
  log "Pulling $IMAGE"
  docker pull --platform "$PLATFORM" "$IMAGE" >/dev/null

  ###################################
  # Remove stale candidate
  ###################################
  if container_exists "$CANDIDATE_NAME"; then
    docker rm -f "$CANDIDATE_NAME" >/dev/null
  fi

  ###################################
  # Run candidate
  ###################################
  log "Starting candidate container"

  RUN_ARGS=(
    --name "$CANDIDATE_NAME"
    --detach
    --platform "$PLATFORM"
    --cpus "$CPU_LIMIT"
    --memory "$MEM_LIMIT"
    --restart unless-stopped
    --log-driver json-file
    --log-opt "max-size=$LOG_MAX_SIZE"
    --log-opt "max-file=$LOG_MAX_FILE"
    --label "com.openclaw.spec-hash=$SPEC_HASH"
    --publish "${HOST_PORT}:${CONTAINER_PORT}"
  )

  [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]] && RUN_ARGS+=(--env-file "$ENV_FILE")
  [[ -n "$NETWORK" ]] && RUN_ARGS+=(--network "$NETWORK")

  docker run "${RUN_ARGS[@]}" "$IMAGE" >/dev/null

  ###################################
  # Health Gate
  ###################################
  if ! wait_for_healthy "$CANDIDATE_NAME" "$HEALTH_TIMEOUT" "$HEALTH_POLL"; then
    docker rm -f "$CANDIDATE_NAME" >/dev/null || true
    fail "Candidate failed health check"
  fi

  ###################################
  # Safe Replace
  ###################################
  if container_exists "$CONTAINER_NAME"; then
    log "Stopping old container"
    docker stop "$CONTAINER_NAME" >/dev/null
    docker rm "$CONTAINER_NAME" >/dev/null
  fi

  docker rename "$CANDIDATE_NAME" "$CONTAINER_NAME"

  log "Deployment successful: $CONTAINER_NAME running $IMAGE"
}

main "$@"
