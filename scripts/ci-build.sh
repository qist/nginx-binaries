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

# ---------- 版本解析: 显式指定优先; latest/留空 -> GitHub releases/latest ----------
#   nginx  : nginx/nginx        tag 形如 release-1.31.8 -> 1.31.8
#   openssl: openssl/openssl    tag 形如 openssl-4.0.3  -> 4.0.3
# CI (Actions 运行器自带 GITHUB_TOKEN 环境变量) 会带认证, 规避匿名 60 次/小时限流
# 解析用 sed 而非 grep -oP: Alpine (busybox grep) / macOS (BSD grep) 无 -P 支持
gh_latest_tag() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL --retry 3 --connect-timeout 10 \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      "https://api.github.com/repos/$1/releases/latest" \
      | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
  else
    curl -fsSL --retry 3 --connect-timeout 10 \
      "https://api.github.com/repos/$1/releases/latest" \
      | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
  fi
}
if [ -z "$VER" ] || [ "$VER" = "latest" ]; then
  TAG="$(gh_latest_tag nginx/nginx)"
  VER="${TAG#release-}"
fi
[ -n "$VER" ] || { echo "!! 无法获取 nginx 最新 release, 可显式传入版本号"; exit 1; }
if [ -z "${OPENSSL_VER:-}" ] || [ "${OPENSSL_VER:-}" = "latest" ]; then
  TAG="$(gh_latest_tag openssl/openssl)"
  OPENSSL_VER="${TAG#openssl-}"
fi
[ -n "$OPENSSL_VER" ] || { echo "!! 无法获取 openssl 最新 release, 可显式 export OPENSSL_VER=x.y.z"; exit 1; }
echo "==> [ci-build] 版本解析: nginx=$VER openssl=$OPENSSL_VER"

# 版本号贯穿: $2(VER) 同时作为 nginx 源码版本 (ci-setup-deps.sh / build-nginx.sh 用 $NGINX_VER)
export NGINX_VER="$VER" OPENSSL_VER

# macOS: 较新 Xcode/SDK 默认部署目标为 15.0, 会让 luajit2/OpenSSL/nginx 在编译或链接阶段
# 因 syscall 兼容问题失败; 显式降到 11.0 以兼容更多 macOS 运行环境, 且让 LLVM 工具链稳定。
if [ "$(uname -s)" = "Darwin" ]; then
  export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
  echo "==> [ci-build] macOS 部署目标: $MACOSX_DEPLOYMENT_TARGET"
fi

bash "$SCRIPT_DIR/ci-setup-deps.sh"
bash "$SCRIPT_DIR/ci-prepare.sh"
# 构建脚本可切换: NGINX_BUILD_SCRIPT=build-nginx-fhs.sh 使用 FHS 路径布局变体
bash "$SCRIPT_DIR/${NGINX_BUILD_SCRIPT:-build-nginx.sh}"
bash "$SCRIPT_DIR/ci-package.sh" "$ROOT" "$VER" "$SUFFIX" "$FMT"

echo "==> [ci-build] 产物: $ROOT/nginx_${VER}_${SUFFIX}.${FMT}"
