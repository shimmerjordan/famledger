#!/bin/sh
# 以 root 入场，把数据目录的属主修成运行用户（默认镜像自带的 node，1000:1000），再降权启动。
#
# 为什么需要：bind mount 的宿主目录不存在时，Docker 会以 root:root 新建它，
# 非 root 进程写不进去，SQLite 直接报 "unable to open database file"，容器反复重启。
# 有了这一步，compose 里直接写宿主路径就能用，不用先去宿主机 chown。
set -e

DATA_DIR="${DATA_DIR:-/data}"
SERVER=/app/server/src/server.js

if [ "$(id -u)" = "0" ]; then
  PUID="${PUID:-1000}"
  PGID="${PGID:-1000}"
  mkdir -p "$DATA_DIR"
  if [ "$(stat -c %u "$DATA_DIR")" != "$PUID" ]; then
    echo "[entrypoint] 修正数据目录属主：$DATA_DIR → $PUID:$PGID"
    if ! chown -R "$PUID:$PGID" "$DATA_DIR"; then
      echo "[entrypoint] 改不了 $DATA_DIR 的属主（多半是网络盘或 ACL）。"
      echo "[entrypoint] 请在宿主机对挂载的目录执行：chown -R $PUID:$PGID <目录>"
      exit 1
    fi
  fi
  export DROP_UID="$PUID" DROP_GID="$PGID" HOME=/home/node
  exec node /app/deploy/drop-privs.mjs "$SERVER"
fi

# 用 --user / compose 的 user: 指定了身份：不动属主，只在写不进去时说清楚怎么办。
if [ ! -w "$DATA_DIR" ]; then
  echo "[entrypoint] 数据目录不可写：$DATA_DIR（当前 uid=$(id -u)）。"
  echo "[entrypoint] 请在宿主机对挂载的目录执行：chown -R $(id -u):$(id -g) <目录>"
  exit 1
fi
exec node "$SERVER"
