#!/usr/bin/env bash
#
# build-libs.sh - 准备 nginx 编译所需的全部依赖 (Linux / macOS 通用)
#
# 产出 (都在 $WORK 下):
#   openssl-<ver>/      官方 OpenSSL 源码  (由 nginx --with-openssl 编译, 静态链入)
#   luajit/             LuaJIT 静态库 + 头文件 (+ 默认 share/lua)
#   mimalloc/           mimalloc 静态库 (override 模式接管 malloc/free)
#   lua/                纯 lua 生态根目录:
#                        cjson.lua  (纯 lua 垫片, 内部用 dkjson, 满足 require("cjson"))
#                        dkjson.lua
#                        socket.lua (纯 lua 占位, 在 nginx 内桥接 ngx.socket)
#                        resty/...  (lua-resty-* 生态全部纯 lua)
#                        waf/...    (qist/waf 纯 lua 防火墙)
#
# 设计要点:
#   * 不编译任何 lua C 扩展 —— lua-cjson / luasocket 都是纯 lua 实现, 跨平台一致
#   * mimalloc 自动 cmake 编译, 不再依赖外部预构建
#   * 平台差异在此脚本内处理, CI 与本机复用同一份逻辑
#
set -e

# ---------- 平台检测 ----------
OS="$(uname -s)"
if [ "$OS" = "Darwin" ]; then
  PLATFORM="macos"
  NPROC="$(sysctl -n hw.ncpu)"
  LDD() { otool -L "$1"; }
else
  PLATFORM="linux"
  NPROC="$(nproc)"
  LDD() { ldd "$1"; }
fi
echo "==> 平台: $PLATFORM | NPROC=$NPROC"

# ---------- 可调参数 ----------
NGINX_VER="${NGINX_VER:-1.31.3}"
# OpenSSL 版本策略: 3.5 LTS 分支最新 patch 自动累加 (LTS 支持到 2030-04; CI 由
# ci-build.sh 动态解析, 此处默认为已知良好版本兜底)。4.x 不跟随: 4.0.x/4.1.0 受
# CVE-2026-121481 (EVP_EncodeBlock 堆溢出); 3.6 系列已 EOL。3.5.10 发布后自动带上
# 2026-11 批次 QUIC CVE-2026-84785/107494/95691/88822 及 Low CVE-2026-107493/124709/35190
OPENSSL_VER="${OPENSSL_VER:-3.5.9}"
OPENSSL_REPO="https://github.com/openssl/openssl.git"
LUAJIT_REPO="https://github.com/openresty/luajit2.git"
MIMALLOC_REPO="https://github.com/microsoft/mimalloc.git"
MIMALLOC_VER="${MIMALLOC_VER:-v2.1.9}"

LNM_REPO="https://github.com/openresty/lua-nginx-module.git"
NDK_REPO="https://github.com/vision5/ngx_devel_kit.git"

# 纯 lua resty 生态清单已抽至 scripts/install-lua-ecosystem.sh (Linux/Windows 共用)

# ---------- 路径 ----------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$ROOT/work}"

# 代理: 默认 github.com 直连 (CI 假设 github 畅通, git clone 不绕代理)。
# GITHUB_VIA_PROXY=1 时不清理 git 代理配置, clone 走 https_proxy 环境变量
# (本地/国内网络 github 直连不稳定时使用, 如 2.186 docker 实测)。
if [ "${GITHUB_VIA_PROXY:-0}" != "1" ]; then
  git config --global --unset http.proxy 2>/dev/null || true
  git config --global --unset https.proxy 2>/dev/null || true
  git config --global http.https://github.com.proxy "" 2>/dev/null || true
fi
mkdir -p "$WORK"
LUA_ROOT="$WORK/lua"
LUAJIT_DIR="$WORK/luajit"

echo "==> 工作目录: $WORK"
echo "==> lua 生态根: $LUA_ROOT"

# ---------- 干净环境 (仅本机 safe-delete 场景需要, CI 不启用) ----------
# 本机 shell 里 `rm` 被 safe-delete 包装会导致 make 删除 .tmp 失败; env -i 可绕过。
# CI (GitHub Actions) 不存在此问题, 设 CLEAN_ENV=1 才启用。
run() {
  if [ "${CLEAN_ENV:-0}" = "1" ]; then
    env -i PATH=/usr/bin:/bin:/usr/local/bin:/usr/sbin:/sbin \
            HOME="$HOME" CC="${CC:-gcc}" CXX="${CXX:-g++}" \
            MAKEFLAGS="-j$NPROC" "$@"
  else
    "$@"
  fi
}

# ---------- 1. 官方 OpenSSL (仅准备源码) ----------
prep_openssl() {
  # OpenSSL 源码放仓库根同级 (与 nginx 源码目录平级), 这样
  # nginx ./configure 用相对路径 --with-openssl=../openssl-<ver> 在本地/CI 都通用
  if [ -d "$ROOT/openssl-$OPENSSL_VER" ]; then
    echo "==> [1] openssl-$OPENSSL_VER 源码已就绪，跳过"
    return
  fi
  echo "==> [1] 克隆官方 OpenSSL $OPENSSL_VER (原生 QUIC + 后量子混合组)"
  rm -rf "$ROOT/openssl-src"
  git clone --depth=1 --branch "openssl-$OPENSSL_VER" "$OPENSSL_REPO" "$ROOT/openssl-src"
  mv "$ROOT/openssl-src" "$ROOT/openssl-$OPENSSL_VER"
  echo "    版本: $($ROOT/openssl-$OPENSSL_VER/VERSION.dat 2>/dev/null | grep -E '^VERSION=' | cut -d= -f2)"
}

# ---------- 2. LuaJIT (静态) ----------
build_luajit() {
  if [ -f "$LUAJIT_DIR/usr/local/lib/libluajit-5.1.a" ]; then
    echo "==> [2] LuaJIT 已就绪，跳过"
    return
  fi
  echo "==> [2] 构建 LuaJIT (静态 + FFI)"
  rm -rf "$WORK/luajit-src"
  git clone --depth=1 "$LUAJIT_REPO" "$WORK/luajit-src"
  cd "$WORK/luajit-src"
  # macOS: luajit2 在较新 Xcode/SDK 下编译/链接需显式部署目标, 否则默认 15.0
  # 触发 syscall 兼容问题导致 make 立即失败; 旧目标 + amalg 是稳定静态编译做法。
  if [ "$(uname -s)" = "Darwin" ]; then
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    LJ_TARGET_SYS="Darwin"
  else
    LJ_TARGET_SYS="Linux"
  fi
  run make BUILDMODE=static amalg \
    TARGET_SYS="$LJ_TARGET_SYS" \
    XCFLAGS="-DLUAJIT_ENABLE_FFI"
  rm -rf "$LUAJIT_DIR" && mkdir -p "$LUAJIT_DIR"
  run make DESTDIR="$LUAJIT_DIR" install
  echo "    LuaJIT 静态库: $(ls "$LUAJIT_DIR/usr/local/lib/libluajit-5.1.a")"
}

# ---------- 3. mimalloc (静态, override 接管 malloc) ----------
build_mimalloc() {
  # mimalloc 在 64 位系统上可能装到 lib/ 或 lib64/, 用 glob 兼容两种路径
  if ls "$WORK"/mimalloc/lib*/libmimalloc.a >/dev/null 2>&1; then
    echo "==> [3] mimalloc 已就绪，跳过"
    return
  fi
  echo "==> [3] 构建 mimalloc $MIMALLOC_VER (静态 + MI_OVERRIDE)"
  rm -rf "$WORK/mimalloc-src"
  git clone --depth=1 --branch "$MIMALLOC_VER" "$MIMALLOC_REPO" "$WORK/mimalloc-src"
  cd "$WORK/mimalloc-src"
  cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DMI_BUILD_STATIC=ON \
    -DMI_BUILD_SHARED=OFF \
    -DMI_BUILD_OBJECT=OFF \
    -DMI_OVERRIDE=ON \
    -DMI_BUILD_TESTS=OFF \
    -DMI_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_PREFIX="$WORK/mimalloc"
  cmake --build build --target mimalloc-static -j"$NPROC"
  cmake --install build
  MIMALLOC_A="$(ls "$WORK"/mimalloc/lib*/libmimalloc.a 2>/dev/null | head -1)"
  echo "    mimalloc 静态库: $MIMALLOC_A"
}

# ---------- 第三方 nginx 模块 ----------
fetch_nginx_modules() {
  cd "$WORK"
  echo "==> 拉取 nginx 第三方模块"
  [ -d lua-nginx-module ] || git clone --depth=1 "$LNM_REPO" lua-nginx-module
  [ -d ngx_devel_kit ]    || git clone --depth=1 "$NDK_REPO" ngx_devel_kit
}

# ---------- 入口 ----------
case "${1:-all}" in
  clean)
    rm -rf "$WORK"
    echo "==> 已清理 $WORK"
    ;;
  all)
    prep_openssl
    build_luajit
    build_mimalloc
    bash "$SCRIPT_DIR/install-lua-ecosystem.sh" "$LUA_ROOT"
    fetch_nginx_modules
    echo "==> 依赖全部就绪"
    ;;
  openssl)   prep_openssl ;;
  luajit)    build_luajit ;;
  mimalloc)  build_mimalloc ;;
  luavm)     bash "$SCRIPT_DIR/install-lua-ecosystem.sh" "$LUA_ROOT" ;;
  modules)   fetch_nginx_modules ;;
  *)
    echo "用法: $0 [all|openssl|luajit|mimalloc|luavm|modules|clean]"
    exit 1
    ;;
esac
