#!/usr/bin/env bash
# Non-destructive verification for deploy/redeploy-proxy.sh and docker-compose.proxy.yml.
# It validates syntax, init-only behavior, secret generation, Compose rendering,
# Docker-internal networking, and external persistence paths without building or
# starting containers.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT"

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

pass() {
  printf '[PASS] %s\n' "$*"
}

assert_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "Expected file to exist: $path"
}

assert_dir() {
  local path="$1"
  [[ -d "$path" ]] || fail "Expected directory to exist: $path"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "Expected output to contain: $needle"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "Output unexpectedly contained sensitive value: $needle"
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

need_command bash
need_command docker
need_command python3

docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is unavailable"

bash -n deploy/redeploy-proxy.sh
pass "redeploy-proxy.sh syntax is valid"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck deploy/redeploy-proxy.sh
  pass "shellcheck passed"
else
  printf '[SKIP] shellcheck is not installed\n'
fi

help_output="$(deploy/redeploy-proxy.sh --help)"
assert_contains "$help_output" 'Persisted configuration:'
assert_contains "$help_output" '$DEPLOY_ROOT/.env'
assert_contains "$help_output" '$DEPLOY_ROOT/data/config.yaml'
assert_contains "$help_output" 'Do not pre-create config.yaml'
pass "help output documents externalized configuration"

tmp_root="$(mktemp -d /tmp/sub2api-redeploy-test.XXXXXX)"
cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

nginx_root="$tmp_root/nginx"
init_output="$(DEPLOY_ROOT="$tmp_root" NGINX_ROOT="$nginx_root" PROJECT_NAME="sub2api-test" SUB2API_IMAGE="sub2api:test" deploy/redeploy-proxy.sh --init-only 2>&1)"
assert_contains "$init_output" "Deploy root: $tmp_root"
assert_contains "$init_output" "Nginx root: $nginx_root"
assert_contains "$init_output" "Env file: $tmp_root/.env"
assert_contains "$init_output" "App config file: $tmp_root/data/config.yaml"
assert_contains "$init_output" "Nginx config: $nginx_root/conf.d/sub2api.conf"
assert_contains "$init_output" 'Initialization complete'

assert_file "$tmp_root/.env"
assert_dir "$tmp_root/data"
assert_dir "$tmp_root/postgres_data"
assert_dir "$tmp_root/redis_data"
assert_dir "$tmp_root/backups"
assert_dir "$nginx_root/conf.d"
assert_dir "$nginx_root/html/.well-known/acme-challenge"
assert_dir "$nginx_root/logs"
assert_dir "$nginx_root/cache"
assert_dir "$nginx_root/certs"
assert_file "$nginx_root/conf.d/sub2api.conf"
assert_file "$nginx_root/certs/default-selfsigned.crt"
assert_file "$nginx_root/certs/default-selfsigned.key"
openssl x509 -in "$nginx_root/certs/default-selfsigned.crt" -noout >/dev/null
openssl rsa -in "$nginx_root/certs/default-selfsigned.key" -check -noout >/dev/null 2>&1

mode="$(stat -c '%a' "$tmp_root/.env")"
[[ "$mode" == "600" ]] || fail "Expected .env mode 600, got $mode"
cert_dir_mode="$(stat -c '%a' "$nginx_root/certs")"
[[ "$cert_dir_mode" == "700" ]] || fail "Expected nginx certs dir mode 700, got $cert_dir_mode"
key_mode="$(stat -c '%a' "$nginx_root/certs/default-selfsigned.key")"
[[ "$key_mode" == "600" ]] || fail "Expected nginx self-signed key mode 600, got $key_mode"

python3 - "$tmp_root/.env" "$init_output" <<'PY'
from pathlib import Path
import re
import sys

env_path = Path(sys.argv[1])
init_output = sys.argv[2]
values = {}
for raw in env_path.read_text().splitlines():
    if not raw or raw.lstrip().startswith('#') or '=' not in raw:
        continue
    key, value = raw.split('=', 1)
    values[key.strip()] = value.strip()

required_hex = ["POSTGRES_PASSWORD", "JWT_SECRET", "TOTP_ENCRYPTION_KEY"]
for key in required_hex:
    value = values.get(key, "")
    if value in {"", "change_this_secure_password"}:
        raise SystemExit(f"{key} was not generated")
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise SystemExit(f"{key} is not a 64-char lowercase hex secret")
    if value in init_output:
        raise SystemExit(f"{key} leaked in init-only output")
PY
pass "init-only creates external directories and hidden fixed secrets"

custom_root="$tmp_root/custom-root"
custom_env="$tmp_root/custom.env"
custom_nginx_root="$tmp_root/custom-nginx"
custom_output="$(DEPLOY_ROOT="$custom_root" NGINX_ROOT="$custom_nginx_root" ENV_FILE="$custom_env" PROJECT_NAME="sub2api-test-custom" SUB2API_IMAGE="sub2api:test" deploy/redeploy-proxy.sh --init-only 2>&1)"
assert_contains "$custom_output" "Deploy root: $custom_root"
assert_contains "$custom_output" "Nginx root: $custom_nginx_root"
assert_contains "$custom_output" "Env file: $custom_env"
assert_file "$custom_env"
assert_file "$custom_nginx_root/conf.d/sub2api.conf"
if [[ -f "$custom_root/.env" ]]; then
  fail "Custom ENV_FILE should not require or create $custom_root/.env"
fi
custom_mode="$(stat -c '%a' "$custom_env")"
[[ "$custom_mode" == "600" ]] || fail "Expected custom env mode 600, got $custom_mode"
DEPLOY_ROOT="$custom_root" \
NGINX_ROOT="$custom_nginx_root" \
ENV_FILE="$custom_env" \
PROJECT_NAME="sub2api-test-custom" \
SUB2API_IMAGE="sub2api:test" \
docker compose --env-file "$custom_env" \
  -f deploy/docker-compose.proxy.yml \
  -p sub2api-test-custom \
  config >/dev/null
pass "custom ENV_FILE works with rendered Compose config"

script_source="$(<deploy/redeploy-proxy.sh)"
assert_not_contains "$script_source" 'compose logs --tail=120 sub2api || true'
assert_not_contains "$script_source" "grep -i 'admin password'"
pass "redeploy script does not auto-dump sensitive app logs"

rendered_json="$tmp_root/rendered-compose.json"
DEPLOY_ROOT="$tmp_root" \
NGINX_ROOT="$nginx_root" \
PROJECT_NAME="sub2api-test" \
SUB2API_IMAGE="sub2api:test" \
docker compose --env-file "$tmp_root/.env" \
  -f deploy/docker-compose.proxy.yml \
  -p sub2api-test \
  config --format json > "$rendered_json"

python3 - "$rendered_json" "$tmp_root" <<'PY'
from pathlib import Path
import json
import sys

cfg = json.loads(Path(sys.argv[1]).read_text())
root = Path(sys.argv[2]).resolve()
services = cfg.get("services", {})
for name in ["sub2api", "postgres", "redis", "nginx"]:
    if name not in services:
        raise SystemExit(f"Missing service: {name}")

expected_images = {
    "postgres": "postgres:18.4-alpine",
    "redis": "redis:8-alpine",
    "nginx": "nginx:1.31-alpine",
}
for name, expected in expected_images.items():
    actual = services[name].get("image", "")
    if actual != expected:
        raise SystemExit(f"{name} image {actual!r}, expected {expected!r}")

expected_network = "sub2api-network"
for name in ["sub2api", "postgres", "redis", "nginx"]:
    networks = services[name].get("networks", {})
    if isinstance(networks, list):
        present = expected_network in networks
    else:
        present = expected_network in networks.keys()
    if not present:
        raise SystemExit(f"{name} is not attached to {expected_network}")

app = services["sub2api"]
app_env = app.get("environment", {})
expected_env = {
    "DATA_DIR": "/app/data",
    "DATABASE_HOST": "postgres",
    "DATABASE_PORT": "5432",
    "REDIS_HOST": "redis",
    "REDIS_PORT": "6379",
}
for key, expected in expected_env.items():
    actual = str(app_env.get(key, ""))
    if actual != expected:
        raise SystemExit(f"sub2api env {key}={actual!r}, expected {expected!r}")

volumes = app.get("volumes", [])
if not any(Path(v.get("source", "")).resolve() == root / "data" and v.get("target") == "/app/data" for v in volumes):
    raise SystemExit("sub2api does not mount external data dir to /app/data")

compose_source = Path("deploy/docker-compose.proxy.yml").read_text()
if "${DEPLOY_ROOT:-/opt/proxy/sub2api}/.env" not in compose_source:
    raise SystemExit("sub2api does not declare the external .env file in docker-compose.proxy.yml")

postgres_volumes = services["postgres"].get("volumes", [])
if not any(Path(v.get("source", "")).resolve() == root / "postgres_data" and v.get("target") == "/var/lib/postgresql/data" for v in postgres_volumes):
    raise SystemExit("postgres data is not externally persisted")

redis_volumes = services["redis"].get("volumes", [])
if not any(Path(v.get("source", "")).resolve() == root / "redis_data" and v.get("target") == "/data" for v in redis_volumes):
    raise SystemExit("redis data is not externally persisted")

nginx_root = root / "nginx"
nginx = services["nginx"]
nginx_ports = nginx.get("ports", [])
if not any(str(p.get("target")) == "80" and str(p.get("published")) == "80" for p in nginx_ports):
    raise SystemExit("nginx does not publish host port 80 to container port 80")
if not any(str(p.get("target")) == "443" and str(p.get("published")) == "443" for p in nginx_ports):
    raise SystemExit("nginx does not publish host port 443 to container port 443")
nginx_volumes = nginx.get("volumes", [])
expected_nginx_mounts = {
    nginx_root / "conf.d": "/etc/nginx/conf.d",
    nginx_root / "html": "/usr/share/nginx/html",
    nginx_root / "logs": "/var/log/nginx",
    nginx_root / "cache": "/var/cache/nginx",
    nginx_root / "certs": "/etc/nginx/certs",
}
for source, target in expected_nginx_mounts.items():
    if not any(Path(v.get("source", "")).resolve() == source and v.get("target") == target for v in nginx_volumes):
        raise SystemExit(f"nginx does not mount {source} to {target}")
if "sub2api" not in json.dumps(nginx.get("depends_on", {}), ensure_ascii=False):
    raise SystemExit("nginx should depend on the sub2api service")
nginx_conf = (nginx_root / "conf.d" / "sub2api.conf").read_text()
if "proxy_pass http://sub2api:8080;" not in nginx_conf:
    raise SystemExit("nginx config does not proxy to Docker service sub2api:8080")
if "/.well-known/acme-challenge/" not in nginx_conf:
    raise SystemExit("nginx config does not expose ACME challenge path for later SSL setup")
if "listen 443 ssl;" not in nginx_conf:
    raise SystemExit("nginx config does not listen on 443 with TLS enabled")
if "http2 on;" not in nginx_conf:
    raise SystemExit("nginx config does not enable HTTP/2 using the non-deprecated directive")
if "listen 443 ssl http2" in nginx_conf:
    raise SystemExit("nginx config uses deprecated listen ... http2 syntax")
if "ssl_certificate /etc/nginx/certs/default-selfsigned.crt;" not in nginx_conf:
    raise SystemExit("nginx config does not reference persisted TLS certificate")
if "ssl_certificate_key /etc/nginx/certs/default-selfsigned.key;" not in nginx_conf:
    raise SystemExit("nginx config does not reference persisted TLS key")
if "X-Forwarded-Proto https" not in nginx_conf:
    raise SystemExit("nginx 443 proxy should forward https scheme")

for name in ["postgres", "redis"]:
    if services[name].get("ports"):
        raise SystemExit(f"{name} unexpectedly exposes host ports")

app_ports = app.get("ports", [])
if not app_ports:
    raise SystemExit("sub2api does not expose the application port")
if not any(str(p.get("host_ip")) == "127.0.0.1" and str(p.get("published")) == "8080" and str(p.get("target")) == "8080" for p in app_ports):
    raise SystemExit("sub2api direct debug port should bind to 127.0.0.1:8080 by default, leaving nginx as public ingress")
PY
pass "Compose config uses one internal network and external persistence paths"

redis_canary='redispw_no_leak_12345'
python3 - "$tmp_root/.env" "$redis_canary" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
secret = sys.argv[2]
lines = path.read_text().splitlines()
out = []
seen = False
for line in lines:
    if line.startswith('REDIS_PASSWORD='):
        out.append(f'REDIS_PASSWORD={secret}')
        seen = True
    else:
        out.append(line)
if not seen:
    out.append(f'REDIS_PASSWORD={secret}')
path.write_text('\n'.join(out) + '\n')
PY

rendered_redis_secret_json="$tmp_root/rendered-compose-redis-secret.json"
DEPLOY_ROOT="$tmp_root" \
NGINX_ROOT="$nginx_root" \
PROJECT_NAME="sub2api-test" \
SUB2API_IMAGE="sub2api:test" \
docker compose --env-file "$tmp_root/.env" \
  -f deploy/docker-compose.proxy.yml \
  -p sub2api-test \
  config --format json > "$rendered_redis_secret_json"

python3 - "$rendered_redis_secret_json" "$redis_canary" <<'PY'
from pathlib import Path
import json
import sys
cfg = json.loads(Path(sys.argv[1]).read_text())
secret = sys.argv[2]
redis = cfg['services']['redis']
command_text = json.dumps(redis.get('command', ''), ensure_ascii=False)
healthcheck_text = json.dumps(redis.get('healthcheck', {}).get('test', ''), ensure_ascii=False)
if secret in command_text:
    raise SystemExit('redis command leaks REDIS_PASSWORD in rendered Compose config')
if secret in healthcheck_text:
    raise SystemExit('redis healthcheck leaks REDIS_PASSWORD in rendered Compose config')
if 'REDIS_PASSWORD' not in command_text or '$$' not in command_text:
    raise SystemExit('redis command should defer password expansion to container runtime')
if 'REDIS_PASSWORD' not in healthcheck_text or '$$' not in healthcheck_text:
    raise SystemExit('redis healthcheck should defer password expansion to container runtime')
PY
pass "Redis command and healthcheck defer password expansion to runtime"

printf '[PASS] All non-destructive deploy tests passed\n'
