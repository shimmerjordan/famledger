#!/usr/bin/env bash
# 构建 Flutter Web 产物到 app/build/web —— deploy/Dockerfile 直接 COPY 这个目录。
#
#   ./scripts/build-web.sh
#
# 为什么 web 产物在镜像外构建：Flutter SDK 解包后 2 GB 起步，而 web 产物与 CPU
# 架构无关，塞进镜像构建只会让双架构镜像把同一份 SDK 下两遍。没装 Flutter 的
# 机器走 deploy/Dockerfile.full（多阶段，第一阶段自带 SDK）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/app"

if ! command -v flutter >/dev/null 2>&1; then
  echo "找不到 flutter。装一个（建议 3.32.x，与 deploy/Dockerfile.full 里钉的版本一致），" >&2
  echo "或者直接用 docker compose -f deploy/docker-compose.build.yml 里的 Dockerfile.full 构建。" >&2
  exit 1
fi

echo "==> flutter: $(flutter --version | head -1)"
cd "$APP"

flutter pub get

# 保持 Flutter 默认的 PWA 策略（offline-first）：会生成 flutter_service_worker.js。
# 这不会把用户钉死在旧版本上 —— 服务端（server/src/modules/static.js）对
# index.html / flutter_bootstrap.js / flutter_service_worker.js / version.json
# 一律 no-cache, must-revalidate，只有带 hash 的内容寻址资源才长缓存，所以
# 升级镜像后浏览器下一次打开就能拿到新的 service worker。
# 想彻底不要 SW 就加 --pwa-strategy=none，但那样离线打不开看板，不划算。
flutter build web --release

OUT="$APP/build/web"
[ -f "$OUT/index.html" ] || { echo "构建没产出 $OUT/index.html" >&2; exit 1; }

echo "==> 产物：$OUT"
du -sh "$OUT"
du -sh "$OUT"/* 2>/dev/null | sort -rh | head -8
