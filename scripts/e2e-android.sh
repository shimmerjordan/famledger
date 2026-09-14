#!/usr/bin/env bash
# Android 真机端到端：自动记账从「其他应用的通知」到「服务端流水」走一遍。
#
#   ./scripts/e2e-android.sh                 # 构建 debug APK → 安装 → 全流程
#   SKIP_BUILD=1 ./scripts/e2e-android.sh    # 复用 app/build 里已有的 APK
#   PORT=48123 OUT=/tmp/e2e ./scripts/e2e-android.sh
#
# 步骤：
#   1. 起本地服务端（临时 DATA_DIR）→ 初始化家庭 → 建「宠物」基金（给快捷回复用）
#   2. adb reverse，手机用 http://127.0.0.1:$PORT 直连本机
#   3. 广播 E2E_LOGIN（debug 构建才有）：headless 引擎用 SessionRepo 登录并落会话，不用在屏幕上打字
#   4. cmd notification allow_listener 放行监听；pm grant POST_NOTIFICATIONS；打开设置页截图
#   5. cmd notification post 一条假支付宝通知（来自 com.android.shell，debug 构建放行；金额每轮随机，避开 10 分钟去重）
#   6. 轮询 GET /transactions?source=notification 直到出现这笔支出 → 截图结果通知
#   7. 广播 E2E_ACTION reply「宠物」→ 服务端流水 fundId 变成宠物基金 → 截图更新后的通知
#
# 只碰自家应用（安装 / 启动 / 授权 / 发通知），不卸载、不动其他应用。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/app"
PKG="com.famledger.app"
LISTENER="$PKG/$PKG.capture.CaptureListenerService"
RECEIVER="$PKG/.capture.E2eReceiver"
PORT="${PORT:-48123}"
BASE="http://127.0.0.1:$PORT"
OUT="${OUT:-$APP/build/e2e-android}"
DATA_DIR="${DATA_DIR:-$OUT/data}"
SKIP_BUILD="${SKIP_BUILD:-0}"
KEEP_SERVER="${KEEP_SERVER:-0}"
E2E_USER="${E2E_USER:-e2e}"
E2E_PASS="${E2E_PASS:-e2e-pass-123}"
APK="$APP/build/app/outputs/flutter-apk/app-debug.apk"
# 金额每轮随机（100–999 元）：管线对「同来源 + 同文本」有 10 分钟去重窗口，连跑两轮同一金额第二轮会被判重复。
NOTIFY_AMOUNT="${NOTIFY_AMOUNT:-$((RANDOM % 900 + 100))}"
NOTIFY_TEXT="${NOTIFY_TEXT:-你有一笔${NOTIFY_AMOUNT}.00元的支出，来自美团}"
EXPECT_CENTS=$((NOTIFY_AMOUNT * 100))
REPLY_TEXT="${REPLY_TEXT:-宠物}"

mkdir -p "$OUT" "$DATA_DIR"
SERVER_PID=""

log() { printf '\n==> %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; }
json() { node -e "const j=JSON.parse(require('fs').readFileSync(0,'utf8'));$1"; }
api() { # api METHOD PATH [JSON]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -X "$method" -H 'content-type: application/json' ${TOKEN:+-H "Authorization: Bearer $TOKEN"} -d "$body" "$BASE/api/v1$path"
  else
    curl -sS -X "$method" ${TOKEN:+-H "Authorization: Bearer $TOKEN"} "$BASE/api/v1$path"
  fi
}
shot() { # shot NAME
  local file="$OUT/e2e-$1.png"
  adb exec-out screencap -p > "$file" && echo "截图：$file"
}
cleanup() {
  if [ -n "$SERVER_PID" ] && [ "$KEEP_SERVER" != "1" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    echo "服务端已停止"
  fi
  adb reverse --remove "tcp:$PORT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── 0. 前置 ──────────────────────────────────────────────────────────────
for bin in adb node curl; do command -v "$bin" >/dev/null || { echo "缺 $bin" >&2; exit 1; }; done
adb get-state >/dev/null 2>&1 || { echo "没有连上的设备（adb devices）" >&2; exit 1; }
echo "设备：$(adb shell getprop ro.product.model | tr -d '\r') Android $(adb shell getprop ro.build.version.release | tr -d '\r') $(adb shell getprop ro.product.manufacturer | tr -d '\r')"

# ── 1. 构建 + 安装 ───────────────────────────────────────────────────────
if [ "$SKIP_BUILD" != "1" ]; then
  log "flutter build apk --debug"
  (cd "$APP" && flutter build apk --debug)
fi
[ -f "$APK" ] || { echo "没有 $APK，先构建" >&2; exit 1; }
log "安装 $APK"
run adb install -r -t "$APK"

# ── 2. 服务端 ────────────────────────────────────────────────────────────
log "起服务端 PORT=$PORT DATA_DIR=$DATA_DIR"
if curl -sf "$BASE/healthz" >/dev/null 2>&1; then
  echo "端口 $PORT 上已经有东西在听（上一轮没收干净？），换 PORT= 或先停掉它" >&2
  exit 1
fi
# exec：让 $! 就是 node 的 pid，trap 里才杀得到
(cd "$ROOT" && exec env PORT="$PORT" HOST=127.0.0.1 DATA_DIR="$DATA_DIR" WEB_ROOT=/nonexistent TRUST_PROXY=0 LOG_LEVEL=info \
  node server/src/server.js > "$OUT/server.log" 2>&1) &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -sf "$BASE/healthz" >/dev/null 2>&1 && break
  sleep 0.2
done
curl -sf "$BASE/healthz" >/dev/null || { echo "服务端没起来，看 $OUT/server.log" >&2; exit 1; }
echo "healthz: $(curl -s "$BASE/healthz")"

TOKEN=""
if [ "$(api GET /setup/status | json 'console.log(j.needsSetup)')" = "true" ]; then
  log "初始化家庭"
  TOKEN="$(api POST /setup "{\"householdName\":\"e2e 家庭\",\"username\":\"$E2E_USER\",\"password\":\"$E2E_PASS\",\"displayName\":\"端到端\"}" | json 'if(!j.token){console.error(j);process.exit(1)};console.log(j.token)')"
else
  log "登录已有家庭"
  TOKEN="$(api POST /auth/login "{\"username\":\"$E2E_USER\",\"password\":\"$E2E_PASS\",\"deviceName\":\"e2e 脚本\",\"platform\":\"linux\"}" | json 'if(!j.token){console.error(j);process.exit(1)};console.log(j.token)')"
fi
echo "token: ${TOKEN:0:12}…"

PET_FUND="$(api GET /funds | json 'const f=(j.items||[]).find(x=>x.name==="'"$REPLY_TEXT"'");console.log(f?f.id:"")')"
if [ -z "$PET_FUND" ]; then
  log "建「$REPLY_TEXT」基金（快捷回复的目标）"
  PET_FUND="$(api POST /funds "{\"name\":\"$REPLY_TEXT\",\"kind\":\"custom\"}" | json 'console.log((j.fund||j).id)')"
fi
echo "宠物基金 id: $PET_FUND"
DEFAULT_FUND="$(api GET /funds | json 'const f=(j.items||[]).find(x=>x.isDefault)||(j.items||[])[0];console.log(f?f.id+" "+f.name:"")')"
echo "默认基金: $DEFAULT_FUND"

# ── 3. adb reverse + 登录 ─────────────────────────────────────────────────
log "adb reverse tcp:$PORT"
run adb reverse "tcp:$PORT" "tcp:$PORT"
adb logcat -c || true
log "广播 E2E_LOGIN（headless 引擎登录并落会话）"
printf '$ adb shell am broadcast -a %s -n %s --es baseUrl %s --es username %s --es password ******\n' "$PKG.E2E_LOGIN" "$RECEIVER" "$BASE" "$E2E_USER"
adb shell am broadcast -a "$PKG.E2E_LOGIN" -n "$RECEIVER" --es baseUrl "$BASE" --es username "$E2E_USER" --es password "$E2E_PASS"
for i in $(seq 1 60); do
  if adb logcat -d -s FamLedgerE2E:I 2>/dev/null | grep -q "E2E_LOGIN: .*ok=true"; then break; fi
  sleep 1
done
adb logcat -d -s FamLedgerE2E:I FamLedgerHeadless:I | tail -n 8
adb logcat -d -s FamLedgerE2E:I | grep -q "E2E_LOGIN: .*ok=true" || { echo "登录没成功，看 logcat FamLedgerE2E" >&2; exit 1; }

# ── 4. 权限 + 设置页 ─────────────────────────────────────────────────────
log "放行通知监听 + 通知权限"
run adb shell cmd notification allow_listener "$LISTENER"
adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null || echo "（pm grant POST_NOTIFICATIONS 不可用，可在设置页里点「允许」）"
# 放行是异步落盘的，给它几秒
for _ in $(seq 1 10); do
  adb shell settings get secure enabled_notification_listeners | tr ':' '\n' | grep -q "$PKG" && break
  sleep 0.5
done
adb shell settings get secure enabled_notification_listeners | tr ':' '\n' | grep "$PKG" || { echo "监听没放行成功（MIUI 可能需要在「通知使用权」里手动开）" >&2; exit 1; }

log "打开自动记账设置页（深链 famledger://settings/capture）"
run adb shell am start -W -a android.intent.action.VIEW -d "famledger://settings/capture" -n "$PKG/.MainActivity" >/dev/null
sleep 4
shot settings

# ── 5. 假支付通知 ────────────────────────────────────────────────────────
log "发假支付宝通知（来自 com.android.shell）"
# 复用同一个 DATA_DIR 时服务端里可能已有上一轮的流水，只认这次新出现的那条
BEFORE_IDS="$(api GET '/transactions?source=notification' | json 'console.log((j.items||[]).map(x=>x.id).join(","))')"
adb logcat -c || true
run adb shell cmd notification post -S bigtext -t "支付宝" fam1 "$NOTIFY_TEXT"

log "轮询服务端 GET /transactions?source=notification（等新流水）"
ROW=""
for i in $(seq 1 60); do
  ROW="$(api GET '/transactions?source=notification' | BEFORE_IDS="$BEFORE_IDS" EXPECT_CENTS="$EXPECT_CENTS" json 'const seen=new Set((process.env.BEFORE_IDS||"").split(",").filter(Boolean));const t=(j.items||[]).find(x=>x.amountCents===Number(process.env.EXPECT_CENTS)&&x.type==="expense"&&!seen.has(x.id));console.log(t?JSON.stringify(t):"")')"
  [ -n "$ROW" ] && break
  sleep 1
done
adb logcat -d -s FamLedgerListener:I FamLedgerHeadless:I FamLedgerNotify:I | tail -n 12
if [ -z "$ROW" ]; then
  adb logcat -d -s FamLedgerNotify:I | grep -q "duplicate" && echo "（管线判成重复：10 分钟内同一来源发过同一段文本。换 NOTIFY_AMOUNT= 再试）" >&2
  echo "60 秒内服务端没出现这笔流水（期望 amountCents=$EXPECT_CENTS）" >&2
  exit 1
fi
echo "服务端流水：$ROW"
TX_ID="$(echo "$ROW" | json 'console.log(j.id)')"
CAPTURE_ID="$(echo "$ROW" | json 'console.log(j.captureId||"")')"
echo "id=$TX_ID captureId=$CAPTURE_ID status=$(echo "$ROW" | json 'console.log(j.status)') fundId=$(echo "$ROW" | json 'console.log(j.fundId)') categoryId=$(echo "$ROW" | json 'console.log(j.categoryId)') confidence=$(echo "$ROW" | json 'console.log(j.confidence)')"

log "截图结果通知"
adb shell cmd statusbar expand-notifications
sleep 2
shot notification
adb shell cmd statusbar collapse
sleep 1

# ── 6. 快捷回复 ──────────────────────────────────────────────────────────
[ -n "$CAPTURE_ID" ] || { echo "流水上没有 captureId，无法测快捷回复" >&2; exit 1; }
log "广播 E2E_ACTION reply「$REPLY_TEXT」（RemoteInput 无法用 adb 驱动，走同一条 onAction 通路）"
adb logcat -c || true
run adb shell am broadcast -a "$PKG.E2E_ACTION" -n "$RECEIVER" --es captureId "$CAPTURE_ID" --es action reply --es text "$REPLY_TEXT"
NEW_FUND=""
for i in $(seq 1 30); do
  NEW_FUND="$(api GET "/transactions/$TX_ID" | json 'console.log((j.transaction||j).fundId||"")')"
  [ "$NEW_FUND" = "$PET_FUND" ] && break
  sleep 1
done
adb logcat -d -s FamLedgerE2E:I | tail -n 3
echo "回复后 fundId=$NEW_FUND（期望 $PET_FUND）"
[ "$NEW_FUND" = "$PET_FUND" ] || { echo "快捷回复没有改到基金" >&2; exit 1; }
echo "回复后流水：$(api GET "/transactions/$TX_ID")"
echo "共享模型：$(api GET /model | json 'console.log("version="+j.version+" categoryDocs="+j.category.totalDocs+" fundDocs="+j.fund.totalDocs)')"

adb shell cmd statusbar expand-notifications
sleep 2
shot notification-updated
adb shell cmd statusbar collapse

log "全部通过。产物在 $OUT"
