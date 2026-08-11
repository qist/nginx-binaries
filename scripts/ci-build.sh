#!/usr/bin/env bash
#
# ci-build.sh - CI 单 step 统一入口 (docker / 直编 / macos 通用)
#
# 串起:
#   1) ci-setup-deps.sh   第三方 nginx 模块 + 系统依赖库 (pcre2/zlib/xz/libxml2/libxslt/brotli)
#   2) ci-prepare.sh      OpenSSL/LuaJIT/mimalloc/lua 生态
#   3) build-nginx.sh     完整 ./configure + make (参数已整合进脚本)
#   4) ci-package.sh      打包成 tar.gz / zip, 落到 $ROOT 产物目录
#
# 调用示例 (docker 内):
#   MODULE_ROOT=/workspace LIBS_PREFIX=/workspace/libs \
#     ./scripts/ci-build.sh /workspace 1.31.3 glibc_amd64 tar.gz
# 调用示例 (直编 / macos):
#   MODULE_ROOT=$GITHUB_WORKSPACE LIBS_PREFIX=$GITHUB_WORKSPACE/libs \
#     ./scripts/ci-build.sh $GITHUB_WORKSPACE 1.31.3 macos_arm64 tar.gz
#
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$1"; VER="$2"; SUFFIX="$3"; FMT="${4:-tar.gz}"
[ -n "$ROOT" ] || { echo "用法: ci-build.sh <ROOT> <VER> <SUFFIX> [tar.gz|zip]"; exit 1; }
echo "==> [ci-build] ROOT=$ROOT VER=$VER SUFFIX=$SUFFIX FMT=$FMT"

export MODULE_ROOT="${MODULE_ROOT:-$ROOT}"
export LIBS_PREFIX="${LIBS_PREFIX:-$ROOT/libs}"
export WORK="${WORK:-$ROOT/work}"
# 版本号贯穿: $2(VER) 同时作为 nginx 源码版本 (ci-setup-deps.sh / build-nginx.sh 用 $NGINX_VER)
export NGINX_VER="${NGINX_VER:-$VER}"

bash "$SCRIPT_DIR/ci-setup-deps.sh"
bash "$SCRIPT_DIR/ci-prepare.sh"
bash "$SCRIPT_DIR/build-nginx.sh"
bash "$SCRIPT_DIR/ci-package.sh" "$ROOT" "$VER" "$SUFFIX" "$FMT"

echo "==> [ci-build] 产物: $ROOT/nginx_${VER}_${SUFFIX}.${FMT}"
