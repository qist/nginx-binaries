#!/usr/bin/env bash
#
# apply-nginx-patches.sh — 把 patches/ 下的源码补丁应用到 nginx 源码树。
# 三个构建脚本（build-nginx.sh / -apps / -fhs）共用，避免逻辑漂移。
#
# 用法: apply-nginx-patches.sh <SRC> <NGINX_VER>
#
# 行为:
#   - 已应用（源码含 proxy_protocol_var）→ 直接返回；
#   - nginx < 1.31.4 → 默认报错退出；ALLOW_UNPATCHED=1 才跳过（产物无该特性）；
#   - 补丁必须 --fuzz=0 干净应用，否则退出非 0（构建 fail-closed）。
#
set -euo pipefail

SRC="${1:?用法: apply-nginx-patches.sh <nginx源码目录> <版本>}"
NGINX_VER="${2:?缺少 nginx 版本}"
SRC="$(cd "$SRC" && pwd)"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="$ROOT/patches/nginx-stream-pp-var.patch"
PP_SRC="$SRC/src/stream/ngx_stream_proxy_module.c"
MIN_VER="1.31.4"   # PROXY protocol v2 写入从 1.31.4 开始；1.31.3 只有 on/off

ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

if [ ! -f "$PATCH" ]; then
  echo "!! 缺少补丁文件: $PATCH" >&2
  exit 1
fi

if ! ver_ge "$NGINX_VER" "$MIN_VER"; then
  if [ "${ALLOW_UNPATCHED:-0}" = "1" ]; then
    echo "==> nginx $NGINX_VER < $MIN_VER，按 ALLOW_UNPATCHED=1 跳过 pp-var 补丁（产物无该特性）"
    exit 0
  fi
  echo "!! nginx $NGINX_VER 不支持 pp-var 补丁：最低需要 $MIN_VER（v2 写支持从该版本开始）" >&2
  echo "   如确需构建旧版本且不要该特性，设置 ALLOW_UNPATCHED=1" >&2
  exit 1
fi

if grep -q "proxy_protocol_var" "$PP_SRC" 2>/dev/null; then
  echo "==> stream pp-var 补丁已应用, 跳过"
  exit 0
fi

echo "==> 应用 stream pp-var 补丁"
cd "$SRC"
if ! patch -p1 --fuzz=0 --dry-run < "$PATCH" >/dev/null 2>&1; then
  echo "!! stream pp-var 补丁无法干净应用（nginx $NGINX_VER），中止构建" >&2
  exit 1
fi
patch -p1 --fuzz=0 < "$PATCH"

if ! grep -q "proxy_protocol_var" "$PP_SRC"; then
  echo "!! stream pp-var 补丁未生效，中止构建" >&2
  exit 1
fi
echo "==> stream pp-var 补丁应用成功"
