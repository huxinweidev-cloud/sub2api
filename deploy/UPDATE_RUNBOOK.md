# Sub2API 标准化近无感更新上线流程

本文记录 `/home/ubuntu/projects/sub2api` 在当前 Docker Compose 部署形态下的标准更新流程。目标是：预构建、可扫描、短窗口切换、失败可快速回滚，并避免误动数据库、Redis、Nginx 和数据卷。

## 适用范围

- 部署目录：`/home/ubuntu/projects/sub2api`
- 持久化目录：`/opt/proxy/sub2api`
- Nginx 目录：`/opt/proxy/nginx`
- Compose 文件：`deploy/docker-compose.proxy.yml`
- Compose 项目名：`sub2api`
- 当前应用镜像：`sub2api:build-server`
- 回滚镜像：`sub2api:previous`

## 基本原则

1. **先验证，后上线**：上线前必须确认当前线上健康、Git 工作区状态、Docker 构建、镜像安全扫描。
2. **先保存回滚镜像**：每次构建新镜像前，先把当前稳定镜像标记为 `sub2api:previous`。
3. **不动数据服务**：常规更新只重建 `sub2api` app 容器，不重建 `postgres`、`redis`。
4. **尽量不动 Nginx**：除非 Nginx 配置发生变化，否则不重建 Nginx 容器。
5. **不清数据卷**：禁止使用会删除 volume 的 Docker 清理命令。
6. **日志脱敏**：汇报时不得粘贴 API key、token、password、secret、数据库/Redis 连接串等敏感信息。
7. **账号池问题单独处理**：如果 `/v1/chat/completions` 返回 `no available accounts`、账号 403、模型无可用账号，部署代码通常不是根因，不能靠重启/重部署解决。

## 一、上线前检查

```bash
cd /home/ubuntu/projects/sub2api

git status --short --branch
git log --oneline --decorate -5

test -x deploy/rollback-sub2api-app.sh

docker compose \
  --env-file /opt/proxy/sub2api/.env \
  -f deploy/docker-compose.proxy.yml \
  -p sub2api \
  ps

curl -fsS http://127.0.0.1:8080/health
curl -fsS http://127.0.0.1/health
```

通过条件：

- `sub2api`、`sub2api-nginx`、`sub2api-postgres`、`sub2api-redis` 均 healthy。
- 两个 `/health` 都返回 `{"status":"ok"}`。
- 工作区没有未预期改动；如果有，应明确是否属于本次部署内容。
- 回滚脚本存在且可执行。

## 二、保存回滚镜像

必须在构建新镜像前执行：

```bash
docker image inspect sub2api:build-server --format 'current {{.Id}} {{.Created}}'
docker tag sub2api:build-server sub2api:previous
docker image inspect sub2api:previous --format 'rollback {{.Id}} {{.Created}}'
```

通过条件：

- `sub2api:previous` 指向上线前的当前稳定镜像。
- 后续回滚脚本可以使用该镜像恢复 app 容器。

## 三、构建新镜像

构建过程中旧服务继续运行。

```bash
cd /home/ubuntu/projects/sub2api

DEPLOY_ROOT=/opt/proxy/sub2api \
NGINX_ROOT=/opt/proxy/nginx \
ENV_FILE=/opt/proxy/sub2api/.env \
SUB2API_IMAGE=sub2api:build-server \
docker compose \
  --env-file /opt/proxy/sub2api/.env \
  -f deploy/docker-compose.proxy.yml \
  -p sub2api \
  build sub2api
```

默认不加 `--no-cache`，减少构建时间和系统压力。只有缓存疑似污染或依赖变化异常时才考虑无缓存构建。

构建完成后确认镜像：

```bash
docker image inspect sub2api:build-server --format 'new {{.Id}} {{.Created}}'
docker image inspect sub2api:previous --format 'rollback {{.Id}} {{.Created}}'
```

通过条件：

- `sub2api:build-server` 是新镜像。
- `sub2api:previous` 仍指向上线前旧镜像。

## 四、镜像安全扫描

优先用本机 Trivy；没有则用容器方式。

```bash
if command -v trivy >/dev/null 2>&1; then
  trivy image --severity CRITICAL,HIGH,MEDIUM --no-progress sub2api:build-server
else
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy:latest \
    image --severity CRITICAL,HIGH,MEDIUM --no-progress sub2api:build-server
fi
```

上线门槛：

- `CRITICAL = 0`
- `HIGH = 0`，或已确认是不可利用/无可修复且用户接受风险。
- 对公开服务和状态服务，不应忽略高危漏洞。

## 五、只替换 app 容器上线

这是唯一短暂影响线上请求的步骤。

```bash
cd /home/ubuntu/projects/sub2api

DEPLOY_ROOT=/opt/proxy/sub2api \
NGINX_ROOT=/opt/proxy/nginx \
ENV_FILE=/opt/proxy/sub2api/.env \
SUB2API_IMAGE=sub2api:build-server \
docker compose \
  --env-file /opt/proxy/sub2api/.env \
  -f deploy/docker-compose.proxy.yml \
  -p sub2api \
  up -d --force-recreate --no-deps sub2api
```

注意：

- 不使用 `--restart-all`。
- 不执行 `docker compose up -d --force-recreate` 全量重建。
- 不重建 `nginx`，除非 Nginx 配置确实变更。

## 六、上线后健康检查

```bash
# 等待 app healthy
for i in $(seq 1 36); do
  h=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' sub2api 2>/dev/null || echo missing)
  echo "health[$i]=$h"
  [ "$h" = healthy ] && break
  sleep 5
done

# Compose 状态
docker compose \
  --env-file /opt/proxy/sub2api/.env \
  -f deploy/docker-compose.proxy.yml \
  -p sub2api \
  ps

# 健康接口
curl -fsS http://127.0.0.1:8080/health
curl -fsS http://127.0.0.1/health

# 镜像确认
docker inspect sub2api --format 'container={{.Name}} image={{.Image}} started={{.State.StartedAt}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}'
docker image inspect sub2api:build-server --format 'active-tag {{.Id}} {{.Created}}'
docker image inspect sub2api:previous --format 'rollback-tag {{.Id}} {{.Created}}'
```

通过条件：

- `sub2api` healthy。
- `/health` 直连和 Nginx 入口都正常。
- `sub2api-nginx`、`sub2api-postgres`、`sub2api-redis` 未被重建，仍 healthy。

## 七、日志检查

```bash
# app 错误关键字
docker logs --since=5m sub2api 2>&1 \
  | grep -Ei 'panic|fatal|error|migration|failed|503|502|504|account_select_failed|no available accounts' \
  | tail -80 || true

# Nginx 502/503/504
tail -n 200 /opt/proxy/nginx/logs/sub2api.ssl.access.log 2>/dev/null \
  | awk '$9 ~ /^50[234]$/ {print}' \
  | tail -20 || true

# 资源快照
docker stats --no-stream \
  --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' \
  sub2api sub2api-nginx sub2api-postgres sub2api-redis
```

判断标准：

- 切换瞬间出现 1 条 `connect() failed` / 502 可能是 app 容器重建窗口导致，应继续观察后续是否持续出现。
- `write: broken pipe` 且应用状态码为 200 通常是客户端断开，不等同部署失败。
- 持续 `panic`、`fatal`、健康检查失败、大量 502/503/504，应立即回滚。
- `account_select_failed` / `no available accounts` 多数属于账号池/上游账号状态问题，应单独排查，不应直接判定为部署失败。

## 八、失败回滚

如果上线后健康失败或错误持续增多，执行：

```bash
cd /home/ubuntu/projects/sub2api
./deploy/rollback-sub2api-app.sh
```

预览模式：

```bash
cd /home/ubuntu/projects/sub2api
./deploy/rollback-sub2api-app.sh --dry-run
```

回滚脚本行为：

- 验证 `sub2api:previous` 存在。
- 将 `sub2api:previous` 重新 tag 为 `sub2api:build-server`。
- 只重建 `sub2api` app 容器。
- 不动 Nginx/Postgres/Redis。
- 不删除数据卷。
- 回滚后自动检查 app 和 Nginx 健康入口。

限制：

- 脚本不会回滚数据库迁移。
- 如果新版本已经执行了不兼容数据库迁移，需额外检查数据库迁移状态和备份策略。

## 九、上线后稳定观察

建议观察 10–30 分钟：

```bash
docker compose \
  --env-file /opt/proxy/sub2api/.env \
  -f deploy/docker-compose.proxy.yml \
  -p sub2api \
  ps

curl -fsS http://127.0.0.1:8080/health
curl -fsS http://127.0.0.1/health

docker logs --since=30m sub2api 2>&1 \
  | grep -Ei 'panic|fatal|error|503|502|504|account_select_failed|no available accounts' \
  | tail -120 || true
```

稳定后可只清理安全对象：

```bash
docker image prune -f
docker builder prune -f --filter 'until=24h'
```

禁止：

```bash
docker system prune --volumes
docker volume prune
docker image prune -a
```

## 十、标准汇报格式

每次部署完成后，按以下格式汇报：

```text
部署结果：成功 / 已回滚 / 阻塞未上线
当前提交：<git short sha>
当前镜像：sub2api:build-server <image id>
回滚镜像：sub2api:previous <image id>
容器状态：sub2api/nginx/postgres/redis healthy 状态
健康检查：127.0.0.1:8080/health、127.0.0.1/health
漏洞扫描：CRITICAL/HIGH/MEDIUM 计数
日志检查：是否有 panic/fatal/持续 502/503/504
短暂影响：是否出现切换窗口 502
回滚方式：./deploy/rollback-sub2api-app.sh
遗留风险：前端测试、账号池、数据库迁移、配置 WARN 等
```
