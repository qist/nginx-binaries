#!/usr/bin/env bash
#
# ci-prepare.sh - 准备「非 nginx 模块」的核心依赖
#   (OpenSSL 源码 / LuaJIT / mimalloc / 纯 lua 生态: resty-* + dkjson shim + luasocket shim + qist/waf)
#
# 第三方 nginx 模块 + 系统依赖库 (pcre2/zlib/xz/libxml2/libxslt) 由 ci-setup-deps.sh 负责。
#
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export WORK="${WORK:-$ROOT/work}"
echo "==> [ci-prepare] root=$ROOT work=$WORK"
bash "$SCRIPT_DIR/build-libs.sh" openssl
bash "$SCRIPT_DIR/build-libs.sh" luajit
bash "$SCRIPT_DIR/build-libs.sh" mimalloc
bash "$SCRIPT_DIR/build-libs.sh" luavm
echo "==> [ci-prepare] 完成"
