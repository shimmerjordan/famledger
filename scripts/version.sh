#!/usr/bin/env bash
# CHANGELOG.md 是版本号的唯一来源：形如 `## 0.1.0 — 2026-09-13`（也认
# `## [0.1.0] — TBD` 这种带方括号、还没定发布日期的写法）的标题里，取其中
# 最大的语义化版本号当作当前版本。同一套做法参考自 explore_journal /
# xyz-studio-max，好让本机与 CI 用同一份解析逻辑——不必靠 git tag：tag 是
# 发布的结果而不是来源，靠它意味着「先打 tag 再构建」，tag 打错了还得删。
#
#   scripts/version.sh   → 打印版本号，例如 0.1.0
#
# 为什么取「最大」而不是「最上面那个」：CHANGELOG 的段落按时间排列，真正
# 决定版本的是其中最高的那个号，与标题先后无关。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep -E '^## ' CHANGELOG.md \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
  | sort -V \
  | tail -1)

if [ -z "$VERSION" ]; then
  echo "::error::CHANGELOG.md 里没有任何形如 '## 0.1.0 — …' 的版本标题，无法确定版本号。" >&2
  exit 1
fi

echo "$VERSION"
