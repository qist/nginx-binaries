#!/usr/bin/env bash
#
# ci-setup-deps.sh - 在 nginx 编译前准备 (CI 各平台 step 统一调用)
#
# 负责:
#   1) 第三方 nginx 模块源码 (ngx_devel_kit 统一用 vision5 版 + 全部第三方模块 + lua 模块)
#   2) 依赖库源码与静态编译 (pcre2 / zlib / xz / libxml2 / libxslt / brotli)
#
# 路径前缀通过环境变量传入 (docker 用 /workspace, 直编/macos 用 $GITHUB_WORKSPACE):
#   MODULE_ROOT   第三方模块源码落在此 (脚本内用 $MODULE_ROOT/xxx 引用)
#   LIBS_PREFIX   依赖库安装到此 (pkg-config / 头文件 / 静态库)
#
# 注意: OpenSSL / LuaJIT / mimalloc / 纯 lua 生态 由 ci-prepare.sh + build-libs.sh 负责,
#       本脚本只管「原 yml 里那些第三方 nginx 模块 + 系统依赖库」。
#
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODULE_ROOT="${MODULE_ROOT:-$ROOT}"
LIBS_PREFIX="${LIBS_PREFIX:-$ROOT/work/libs}"
NGINX_VER="${NGINX_VER:-1.31.3}"

# ---------- 代理设置 ----------
# GitHub CI 环境不配置任何代理(默认 CI=true, 直连外网, 包括 github.com)。
# 本地 docker 实测(192.168.2.186)若已设置 http_proxy/https_proxy 环境变量, 则透传给
# curl/wget 用于下载官方源/源码包; github.com 始终直连(不配置 git 代理)。
if [ -n "${CI:-}" ]; then
  echo "==> CI 环境: 不设置代理, 全部直连(含 github.com)"
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
  git config --global --unset http.proxy 2>/dev/null || true
  git config --global --unset https.proxy 2>/dev/null || true
else
  if [ -n "${https_proxy:-}" ]; then
    export https_proxy="${https_proxy}"
    export http_proxy="${http_proxy:-${https_proxy}}"
    echo "==> 已透传环境代理(仅用于 curl/wget 下载, github 直连): ${https_proxy}"
  elif [ -n "${http_proxy:-}" ]; then
    export http_proxy="${http_proxy}"
    echo "==> 已透传环境代理(仅用于 curl/wget 下载, github 直连): ${http_proxy}"
  fi
  # github 直连: 清空 git 的全局代理, 确保 clone 不绕代理
  git config --global --unset http.proxy 2>/dev/null || true
  git config --global --unset https.proxy 2>/dev/null || true
  git config --global http.https://github.com.proxy "" 2>/dev/null || true
fi

# 并发数: Linux/docker 用 nproc, macOS 用 sysctl
if [ "$(uname -s)" = "Darwin" ]; then
  NPROC="$(sysctl -n hw.ncpu)"
else
  NPROC="$(nproc)"
fi

mkdir -p "$LIBS_PREFIX"
mkdir -p "$WORK"
echo "==> [ci-setup-deps] MODULE_ROOT=$MODULE_ROOT  LIBS_PREFIX=$LIBS_PREFIX  NPROC=$NPROC"

# ---------- 0. 拉取 nginx 源码 (官方 tarball, 自带 ./configure, 放 $WORK/nginx-$NGINX_VER) ----------
# 注意: 用 tarball 而非 git clone, 因为 clone 的 release 分支里顶层 ./configure 可能缺失,
#       而 build-nginx.sh 的 SRC 优先取 $WORK/nginx-$NGINX_VER (tarball 源, 确定含 configure)
NGINX_SRC="$WORK/nginx-$NGINX_VER"
if [ ! -f "$NGINX_SRC/configure" ]; then
  echo "==> 下载 nginx-$NGINX_VER tarball -> $NGINX_SRC"
  NGINX_TARBALL="$(mktemp "${TMPDIR:-/tmp}/nginx-XXXXXX.tar.gz")"
  # 先下载到临时文件再解包: 避免网络抖动/代理拦截返回 HTML 错误页时,
  # curl 管道直接喂给 tar 导致 "tar: invalid magic / short read" 这类隐蔽失败。
  # 校验 gzip 魔数(1f 8b)并带重试, 失败时明确报错而非静默。
  download_ok=0
  for attempt in 1 2 3; do
    echo "    (尝试 $attempt/3) 下载 https://nginx.org/download/nginx-$NGINX_VER.tar.gz"
    if curl -fsSL "https://nginx.org/download/nginx-$NGINX_VER.tar.gz" -o "$NGINX_TARBALL" \
       && [ -s "$NGINX_TARBALL" ] \
       && head -c2 "$NGINX_TARBALL" | od -An -tx1 | tr -d ' \n' | grep -q '^1f8b'; then
      echo "    下载成功且为有效 gzip 包"
      download_ok=1
      break
    fi
    echo "    下载校验失败, 1 秒后重试"
    sleep 1
  done
  if [ "$download_ok" -ne 1 ]; then
    echo "!! 下载 nginx-$NGINX_VER tarball 失败 (非 gzip 内容或网络错误)" >&2
    rm -f "$NGINX_TARBALL"
    exit 1
  fi
  tar xzf "$NGINX_TARBALL" -C "$WORK"
  rm -f "$NGINX_TARBALL"
fi
# 清掉可能残留的 $MODULE_ROOT/nginx (git 仓库, 缺 configure, 会误导 build-nginx.sh)
if [ -d "$MODULE_ROOT/nginx" ] && [ "$MODULE_ROOT/nginx" != "$NGINX_SRC" ]; then
  echo "==> 移除残留的 $MODULE_ROOT/nginx (改用 tarball 源)"
  rm -rf "$MODULE_ROOT/nginx"
fi

# ---------- 1. 第三方 nginx 模块源码 ----------
echo "==> 拉取第三方 nginx 模块"
cd "$MODULE_ROOT"
clone() {  # repo_url dir [branch]
  local repo="$1" dir="$2" br="${3:-}"
  if [ -d "$dir" ]; then echo "    (已存在) $dir"; return; fi
  if [ -n "$br" ]; then
    git clone --depth=1 --recursive -b "$br" "$repo" "$dir"
  else
    git clone --depth=1 --recursive "$repo" "$dir"
  fi
}
clone https://github.com/vision5/ngx_devel_kit.git                           ngx_devel_kit
clone https://github.com/openresty/set-misc-nginx-module.git                   set-misc-nginx-module
clone https://github.com/yaoweibin/ngx_http_substitutions_filter_module.git    ngx_http_substitutions_filter_module
clone https://github.com/atomx/nginx-http-auth-digest.git                      nginx-http-auth-digest
# 与发布 CI (build-nginx.yml) 一致: xiaokai-wang/nginx_upstream_check_module
# 注意: upsync 需要的 ngx_http_upstream_check_add/delete_dynamic_peer 符号由
#       check_1.20.1+.patch 注入 nginx 核心 (src/http/ngx_http_upstream.c), 不是模块 .c 自带
clone https://github.com/xiaokai-wang/nginx_upstream_check_module.git      nginx_upstream_check_module
clone https://github.com/FRiCKLE/ngx_cache_purge.git                           ngx_cache_purge
clone https://github.com/weibocom/nginx-upsync-module.git                      nginx-upsync-module
clone https://github.com/openresty/echo-nginx-module.git                       echo-nginx-module
clone https://github.com/evanmiller/mod_zip.git                               mod_zip
clone https://github.com/GUI/nginx-upstream-dynamic-servers.git               nginx-upstream-dynamic-servers
clone https://github.com/openresty/headers-more-nginx-module.git              headers-more-nginx-module
clone https://github.com/vozlt/nginx-module-vts.git                            nginx-module-vts
clone https://github.com/vozlt/nginx-module-sts.git                           nginx-module-sts
clone https://github.com/vozlt/nginx-module-stream-sts.git                    nginx-module-stream-sts
clone https://github.com/arut/nginx-dav-ext-module.git                         nginx-dav-ext-module
clone https://github.com/aperezdc/ngx-fancyindex.git                           ngx-fancyindex
clone https://github.com/google/ngx_brotli.git                                ngx_brotli
# lua 模块 (ngx_devel_kit 已统一用 vision5 版, lua 生态共用同一份)
clone https://github.com/openresty/lua-nginx-module.git                       lua-nginx-module
clone https://github.com/openresty/stream-lua-nginx-module.git                stream-lua-nginx-module
clone https://github.com/openresty/lua-upstream-nginx-module.git              lua-upstream-nginx-module

# ---------- 2. 依赖库 (pcre2 / zlib / xz / libxml2 / libxslt / brotli) ----------
echo "==> 编译依赖库到 $LIBS_PREFIX"
cd "$MODULE_ROOT"

# 2.1 pcre2
if [ ! -d "$MODULE_ROOT/pcre2" ]; then
  git clone --depth=1 --recursive -b pcre2-10.42 https://github.com/PCRE2Project/pcre2.git
fi
cd "$MODULE_ROOT/pcre2" && ./autogen.sh && cd "$MODULE_ROOT"

# 2.2 zlib
if [ ! -d "$MODULE_ROOT/zlib" ]; then
  git clone --depth=1 --recursive -b v1.3.2 https://github.com/madler/zlib.git
fi
cd "$MODULE_ROOT/zlib" && ./configure --prefix="$LIBS_PREFIX" --static && make -j"$NPROC" install && cd "$MODULE_ROOT"

# 2.3 xz
if [ ! -d "$MODULE_ROOT/xz" ]; then
  git clone --depth=1 --recursive https://github.com/tukaani-project/xz.git
fi
cd "$MODULE_ROOT/xz" && mkdir -p build && cd build && \
  cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
           -DCMAKE_INSTALL_PREFIX="$LIBS_PREFIX" -DCMAKE_POSITION_INDEPENDENT_CODE=ON && \
  make -j"$NPROC" install && cd "$MODULE_ROOT"

# 2.4 libxml2
if [ ! -d "$MODULE_ROOT/libxml2" ]; then
  curl -sL https://download.gnome.org/sources/libxml2/2.12/libxml2-2.12.9.tar.xz | tar xJ
  mv libxml2-2.12.9 libxml2
fi
cd "$MODULE_ROOT/libxml2" && \
  ./configure --prefix="$LIBS_PREFIX" --libdir="$LIBS_PREFIX/lib" \
             --enable-static --disable-shared --with-pic \
             --without-python --without-icu --without-lzma --with-zlib="$LIBS_PREFIX" && \
  make -j"$NPROC" install && cd "$MODULE_ROOT"

# 2.5 libxslt
if [ ! -d "$MODULE_ROOT/libxslt" ]; then
  curl -sL https://download.gnome.org/sources/libxslt/1.1/libxslt-1.1.39.tar.xz | tar xJ
  mv libxslt-1.1.39 libxslt
fi
export PATH="$LIBS_PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$LIBS_PREFIX/lib/pkgconfig:$LIBS_PREFIX/lib64/pkgconfig:$LIBS_PREFIX/lib/x86_64-linux-gnu/pkgconfig:$LIBS_PREFIX/lib/aarch64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
export LDFLAGS="-L$LIBS_PREFIX/lib -L$LIBS_PREFIX/lib64"
export C_INCLUDE_PATH="$LIBS_PREFIX/include"
export LIBRARY_PATH="$LIBS_PREFIX/lib:$LIBS_PREFIX/lib64"
cd "$MODULE_ROOT/libxslt" && \
  ./configure --prefix="$LIBS_PREFIX" --libdir="$LIBS_PREFIX/lib" \
             --enable-static --disable-shared --with-pic --without-python --without-crypto && \
  make -j"$NPROC" install && cd "$MODULE_ROOT"

# 2.6 brotli (ngx_brotli 内嵌)
cd "$MODULE_ROOT/ngx_brotli/deps/brotli"
# 清掉旧 CMake 缓存, 避免源码树在不同挂载路径复用 (如裸机→docker) 时
# CMakeCache.txt 记录的上次绝对路径与当前路径冲突导致 cmake 报错
rm -rf out
mkdir -p out && cd out
cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX=./installed ..
cmake --build . --config Release --target brotlienc
make install
cd "$MODULE_ROOT"

echo "==> [ci-setup-deps] 完成"
echo "    模块源码: $MODULE_ROOT/{ngx_devel_kit,set-misc-nginx-module,...,lua-nginx-module}"
echo "    依赖库  : $LIBS_PREFIX/{lib,include}"
