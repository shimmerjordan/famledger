#!/usr/bin/env bash
# 本机跑服务端（前台，Ctrl-C 停）。数据落 server/data/，和容器里的 /data 分开，
# 随便删，别混用同一个目录 —— 那边的 secret.key 换了会把全家踢下线。
#
#   ./scripts/dev.sh                 # 48090，顺带把 app/build/web 发出去
#   PORT=48099 ./scripts/dev.sh      # 换端口
#   WEB_ROOT=/dev/null ./scripts/dev.sh   # 只要 API，不发静态（会显示说明页）
#
# 先跑 ./scripts/build-web.sh 才有 web 产物；没有也能起，服务端见 WEB_ROOT 里
# 没有 index.html 会发一个说明页。手机端调试直接把 App 的服务器地址填
# http://<本机内网 IP>:48090 即可（Android 模拟器用 10.0.2.2）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export PORT="${PORT:-48090}"
export HOST="${HOST:-0.0.0.0}"
export DATA_DIR="${DATA_DIR:-./server/data}"
export WEB_ROOT="${WEB_ROOT:-./app/build/web}"
# 本机直连，没有反代：TRUST_PROXY 必须是 0，否则任何人都能用一个伪造的
# X-Forwarded-For 把登录限流绕过去。容器里默认是 1，因为那边前面有 CF Tunnel。
export TRUST_PROXY="${TRUST_PROXY:-0}"
export LOG_LEVEL="${LOG_LEVEL:-debug}"
export TZ="${TZ:-Asia/Shanghai}"
export NODE_ENV="${NODE_ENV:-development}"

echo "==> node $(node -v)  PORT=$PORT DATA_DIR=$DATA_DIR WEB_ROOT=$WEB_ROOT TRUST_PROXY=$TRUST_PROXY"
echo "==> http://127.0.0.1:$PORT/   健康检查 http://127.0.0.1:$PORT/healthz"

# exec：Ctrl-C 的 SIGINT 直接送到 node，不经这层 shell 转手。
exec node server/src/server.js
