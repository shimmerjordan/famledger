# ---------------------------------------------------------------------------
# famledger 运行镜像：**一个** Node 进程，既出 /api/v1/*，也把 Flutter Web 产物
# 当静态站发出去 —— 一个端口 48090、一个容器、一个 SQLite 文件。
#
#   docker build -f deploy/Dockerfile -t famledger:dev .     # context = 仓库根
#
# 和 explore_journal 那个合并镜像的取舍不同：那边两个服务（Rust + Node）必须共存，
# 所以背了 supervisord + gosu + entrypoint 一整套；这里只有一个进程，再塞进程管理器
# 纯属给自己找事 —— PID 1 就是 node，docker stop 的 SIGTERM 直接送到它手上，容器
# 的退出码也是它的退出码，日志不用过一层。
#
# Web 产物在镜像**外**构建（scripts/build-web.sh 或 CI），这里只 COPY：Flutter SDK
# 解包后 2 GB 起步，而 web 产物与 CPU 架构无关，放进镜像构建只会让双架构镜像把同
# 一份 SDK 下载两遍。没装 Flutter 的机器用 deploy/Dockerfile.full（多阶段自带 SDK）。
# ---------------------------------------------------------------------------
FROM node:24-bookworm-slim

# bookworm-slim 里 curl 和 wget 都没有，下面的 HEALTHCHECK 得自己带一个。
# tzdata 是为了 TZ=Asia/Shanghai 真的生效：缺了它 Node 会静默回落到 UTC，
# 「本月支出」「月报」这些按自然月切的口径会整整差 8 小时。
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 后端零 npm 依赖：拷进来就能跑，没有 npm install、没有 node_modules、没有 lock 漂移。
# test/ 也一并进来（几十 KB），换来的是可疑构建能直接在容器里自证：
#   docker exec famledger sh -c 'cd /app/server && node --test test/*.test.js'
COPY server/ /app/server/

# Flutter Web 产物。
# 刻意**不** --chown 给 node：默认 root:root 意味着运行期那个降权进程对自己的静态
# 资源没有写权限。万一服务被打穿，可写的 /web 就能被塞一个改过的 main.dart.js 去钓
# 下一个登录的管理员；运行期本来就不需要往 /web 写东西，这个只读一分钱不花。
# 也刻意**不**加 --chmod=0644：那个标志对目录同样生效，丢了执行位的目录再也无法遍历，
# assets/、canvaskit/ 会整片打不开。
# 仓库里用 app/build/web/.gitkeep 保住这个目录：没构建过 web 也必须能 build 出镜像，
# 服务端见 WEB_ROOT 里没有 index.html 会发一个说明页（见 src/modules/static.js）。
COPY app/build/web/ /web/

# 数据目录先建好并给 node：named volume 首次使用会继承镜像里的属主。
RUN mkdir -p /data && chown node:node /data

# 服务本身不用 root 跑，但容器以 root 入场：bind mount 的宿主目录常常是 Docker 以
# root:root 新建的，入口脚本先把 /data 的属主修成 node（UID 1000，可用 PUID/PGID 改），
# 再用 drop-privs.mjs 降权加载服务端。所以这里**不写** USER node。
COPY deploy/docker-entrypoint.sh deploy/drop-privs.mjs /app/deploy/

# TRUST_PROXY 默认 1：这镜像就是奔着「NAS + Cloudflare Tunnel」去的，隧道过来的请求
# 源 IP 永远是 127.0.0.1，不认 CF-Connecting-IP 的话登录限流会把全世界塞进同一个桶 ——
# 等于没有限流，还顺手把自家人也锁在外面。**直接把端口暴露在局域网里用时设回 0**，
# 否则任何人都能伪造 X-Forwarded-For 绕过限流。
ENV PORT=48090 \
    HOST=0.0.0.0 \
    DATA_DIR=/data \
    WEB_ROOT=/web \
    TRUST_PROXY=1 \
    NODE_ENV=production \
    TZ=Asia/Shanghai

# /data 里是 famledger.db（WAL，另有 -wal/-shm 两个伴生文件）与 secret.key（0600）。
# secret.key 丢了 = 全家重新登录 + 库里加密的 AI/WebDAV 凭据全成乱码，备份要带上它。
VOLUME ["/data"]
EXPOSE 48090

# start-period 给 15 s：首启要建库、跑迁移、种默认类别，比稳态启动慢。
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS http://127.0.0.1:48090/healthz || exit 1

# 入口脚本最后 exec node，降权后在同一个进程里加载服务端：PID 1 仍是 node 本人，
# SIGTERM 不会被 sh 或 npm 吞掉（被吞掉的后果是每次 docker stop 都等满 10 s 再被
# SIGKILL，WAL 恰好写到一半）。
ENTRYPOINT ["/app/deploy/docker-entrypoint.sh"]
