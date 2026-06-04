#!/usr/bin/env bash
# =============================================================================
# Roll back Sub2API app container to the previously saved Docker image.
#
# Safe scope:
#   - Retags sub2api:previous as sub2api:build-server by default.
#   - Recreates ONLY the sub2api app container with --no-deps.
#   - Does NOT recreate nginx/postgres/redis.
#   - Does NOT delete images, containers, volumes, or data directories.
#
# Typical usage after a failed deploy:
#   cd /home/ubuntu/projects/sub2api
#   ./deploy/rollback-sub2api-app.sh
# =============================================================================

set -Eeuo pipefail

DEFAULT_DEPLOY_ROOT="/opt/proxy/sub2api"
DEFAULT_NGINX_ROOT="/opt/proxy/nginx"
DEPLOY_ROOT="${DEPLOY_ROOT:-$DEFAULT_DEPLOY_ROOT}"
NGINX_ROOT="${NGINX_ROOT:-$DEFAULT_NGINX_ROOT}"
PROJECT_NAME="${PROJECT_NAME:-sub2api}"
SUB2API_IMAGE="${SUB2API_IMAGE:-sub2api:build-server}"
ROLLBACK_IMAGE="${ROLLBACK_IMAGE:-sub2api:previous}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
WAIT_INTERVAL="${WAIT_INTERVAL:-5}"
SKIP_HEALTH=0
DRY_RUN=0

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/docker-compose.proxy.yml}"
ENV_FILE="${ENV_FILE:-$DEPLOY_ROOT/.env}"

usage() {
  cat <<'EOF'
Usage:
  deploy/rollback-sub2api-app.sh [options]

Options:
  --dry-run       Print the rollback actions without changing containers/images.
  --skip-health   Skip post-rollback health checks.
  -h, --help      Show this help.

Environment variables:
  DEPLOY_ROOT      Persistent root directory. Default: /opt/proxy/sub2api
  NGINX_ROOT       Nginx root. Default: /opt/proxy/nginx
  PROJECT_NAME     Docker Compose project name. Default: sub2api
  COMPOSE_FILE     Compose file path. Default: deploy/docker-compose.proxy.yml
  ENV_FILE         Env file path. Default: $DEPLOY_ROOT/.env
  SUB2API_IMAGE    Active image tag. Default: sub2api:build-server
  ROLLBACK_IMAGE   Rollback image tag. Default: sub2api:previous
  HEALTH_TIMEOUT   Health wait timeout in seconds. Default: 180

Rollback behavior:
  1. Verify ROLLBACK_IMAGE exists.
  2. Tag ROLLBACK_IMAGE as SUB2API_IMAGE.
  3. Run docker compose up -d --force-recreate --no-deps sub2api.
  4. Check container health and /health probes unless --skip-health is set.
EOF
}

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --skip-health)
      SKIP_HEALTH=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

export DEPLOY_ROOT NGINX_ROOT PROJECT_NAME SUB2API_IMAGE ENV_FILE

compose() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p "$PROJECT_NAME" "$@"
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY-RUN]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

image_id() {
  docker image inspect "$1" --format '{{.Id}}' 2>/dev/null || true
}

container_health() {
  local name="$1"
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || printf 'missing'
}

wait_for_app_health() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  local app
  log "Waiting for sub2api to become healthy, timeout=${HEALTH_TIMEOUT}s"
  while (( SECONDS < deadline )); do
    app="$(container_health sub2api)"
    if [[ "$app" == "healthy" ]]; then
      log "sub2api is healthy"
      return 0
    fi
    printf '[INFO] health: sub2api=%s\n' "$app"
    sleep "$WAIT_INTERVAL"
  done
  compose ps || true
  fail "sub2api did not become healthy before timeout"
}

health_probes() {
  log "Running rollback health probes"
  compose exec -T sub2api wget -q -T 5 -O /dev/null http://localhost:8080/health
  if docker inspect sub2api-nginx >/dev/null 2>&1; then
    compose exec -T nginx wget -q -T 5 -O /dev/null http://127.0.0.1/health
  else
    warn "sub2api-nginx container not found; skipped nginx health probe"
  fi
  curl -fsS http://127.0.0.1:8080/health >/dev/null
  curl -fsS http://127.0.0.1/health >/dev/null || warn "Host nginx/HTTP health probe failed; app rollback may still be healthy. Inspect nginx if needed."
}

main() {
  cd "$REPO_ROOT"

  command -v docker >/dev/null || fail "docker command not found"
  [[ -f "$COMPOSE_FILE" ]] || fail "Compose file not found: $COMPOSE_FILE"
  [[ -f "$ENV_FILE" ]] || fail "Env file not found: $ENV_FILE"

  local rollback_id current_id
  rollback_id="$(image_id "$ROLLBACK_IMAGE")"
  [[ -n "$rollback_id" ]] || fail "Rollback image not found: $ROLLBACK_IMAGE. A previous deploy must tag it before rollout."
  current_id="$(image_id "$SUB2API_IMAGE")"

  log "Rollback image: $ROLLBACK_IMAGE -> $rollback_id"
  if [[ -n "$current_id" ]]; then
    log "Current image:  $SUB2API_IMAGE -> $current_id"
  else
    warn "Current image tag not found yet: $SUB2API_IMAGE"
  fi

  log "Retagging $ROLLBACK_IMAGE as $SUB2API_IMAGE"
  run docker tag "$ROLLBACK_IMAGE" "$SUB2API_IMAGE"

  log "Recreating only the Sub2API app container; nginx/postgres/redis are untouched"
  run docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up -d --force-recreate --no-deps sub2api

  if [[ "$DRY_RUN" == "1" ]]; then
    log "Dry run complete; no changes were made"
    exit 0
  fi

  if [[ "$SKIP_HEALTH" == "1" ]]; then
    warn "Skipped health checks by request"
    compose ps
  else
    wait_for_app_health
    health_probes
    compose ps
  fi

  log "Rollback complete. Active image tag $SUB2API_IMAGE now points to $ROLLBACK_IMAGE content."
  warn "This script does not roll back database migrations. If a failed deploy already applied incompatible migrations, inspect the app/database manually."
}

main "$@"
