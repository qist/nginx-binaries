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
OPENSSL_VER="${OPENSSL_VER:-3.6.3}"
OPENSSL_REPO="https://github.com/openssl/openssl.git"
LUAJIT_REPO="https://github.com/openresty/luajit2.git"
MIMALLOC_REPO="https://github.com/microsoft/mimalloc.git"
MIMALLOC_VER="${MIMALLOC_VER:-v2.1.9}"

LNM_REPO="https://github.com/openresty/lua-nginx-module.git"
NDK_REPO="https://github.com/vision5/ngx_devel_kit.git"

# 纯 lua resty 生态 (clone --depth=1 后复制 lib/ 进 lua root)
RESTY_LIBS=(
  "https://github.com/openresty/lua-resty-core.git"
  "https://github.com/openresty/lua-resty-lrucache.git"
  "https://github.com/openresty/lua-resty-memcached.git"
  "https://github.com/openresty/lua-resty-mysql.git"
  "https://github.com/openresty/lua-resty-redis.git"
  "https://github.com/openresty/lua-resty-dns.git"
  "https://github.com/openresty/lua-resty-upload.git"
  "https://github.com/openresty/lua-resty-websocket.git"
  "https://github.com/openresty/lua-resty-lock.git"
  "https://github.com/cloudflare/lua-resty-logger-socket.git"
  "https://github.com/openresty/lua-resty-string.git"
  "https://github.com/cloudflare/lua-resty-cookie.git"
  "https://github.com/ledgetech/lua-resty-http.git"
  "https://github.com/api7/lua-resty-ipmatcher.git"
  "https://github.com/ElvinEfendi/lua-resty-global-throttle.git"
)
DKJSON_REPO="https://github.com/LuaDist/dkjson.git"
WAF_REPO="https://github.com/qist/waf.git"

# ---------- 路径 ----------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/work}"

# 代理: CI 与本地均不配置 git 代理, github.com 始终直连(避免 clone 绕代理失败)。
# 非 CI 环境若存在 http_proxy/https_proxy, 仅透传给 curl/wget 下载源码包。
git config --global --unset http.proxy 2>/dev/null || true
git config --global --unset https.proxy 2>/dev/null || true
git config --global http.https://github.com.proxy "" 2>/dev/null || true
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
  run make BUILDMODE=static XCFLAGS="-DLUAJIT_ENABLE_FFI" > /tmp/lj_make.log 2>&1
  rm -rf "$LUAJIT_DIR" && mkdir -p "$LUAJIT_DIR"
  run make DESTDIR="$LUAJIT_DIR" install > /tmp/lj_install.log 2>&1
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
    -DCMAKE_INSTALL_PREFIX="$WORK/mimalloc" > /tmp/mi_conf.log 2>&1
  cmake --build build --target mimalloc-static -j"$NPROC" > /tmp/mi_build.log 2>&1 || {
    echo "    [!] mimalloc build 失败, 输出如下:"; tail -40 /tmp/mi_build.log; exit 1; }
  cmake --install build > /tmp/mi_install.log 2>&1 || {
    echo "    [!] mimalloc install 失败, 输出如下:"; tail -40 /tmp/mi_install.log; exit 1; }
  MIMALLOC_A="$(ls "$WORK"/mimalloc/lib*/libmimalloc.a 2>/dev/null | head -1)"
  echo "    mimalloc 静态库: $MIMALLOC_A"
}

# ---------- 4. 纯 lua 生态 ----------
install_lua_ecosystem() {
  echo "==> [4] 安装纯 lua 生态 (全部纯 lua, 无 C 扩展)"
  mkdir -p "$LUA_ROOT/resty" "$LUA_ROOT/waf"
  cd "$WORK"

  # 4.1 resty-* 生态: 复制各仓库 lib/ 下的 lua 文件
  for repo in "${RESTY_LIBS[@]}"; do
    name="$(basename "$repo" .git)"
    echo "    - $name"
    rm -rf "$WORK/$name-tmp"
    git clone --depth=1 "$repo" "$WORK/$name-tmp"
    # resty 子目录
    if [ -d "$WORK/$name-tmp/lib/resty" ]; then
      cp -r "$WORK/$name-tmp/lib/resty/." "$LUA_ROOT/resty/" 2>/dev/null || true
    fi
    # 顶层 lua 文件 (如 lua-resty-core 的 resty/*.lua 已覆盖, 这里兜底)
    if [ -d "$WORK/$name-tmp/lib" ]; then
      cp -r "$WORK/$name-tmp/lib/." "$LUA_ROOT/" 2>/dev/null || true
    fi
    rm -rf "$WORK/$name-tmp"
  done

  # 4.2 dkjson (纯 lua JSON) + cjson 垫片 (满足 waf 的 require("cjson"))
  echo "    - dkjson + cjson 垫片"
  rm -rf "$WORK/dkjson-tmp"
  git clone --depth=1 "$DKJSON_REPO" "$WORK/dkjson-tmp"
  cp "$WORK/dkjson-tmp/dkjson.lua" "$LUA_ROOT/dkjson.lua"
  cat > "$LUA_ROOT/cjson.lua" <<'LUA'
-- 纯 lua 的 cjson 兼容垫片, 内部用 dkjson 实现
-- 满足 waf 的 require("cjson") / cjson.encode / cjson.decode
local dkjson = require("dkjson")
local cjson = {}
function cjson.encode(v)
  return dkjson.encode(v, { indent = false })
end
function cjson.decode(s)
  local ok, res = pcall(dkjson.decode, s, 1, nil)
  if not ok then
    error(res)
  end
  return res
end
return cjson
LUA
  rm -rf "$WORK/dkjson-tmp"

  # 4.3 luasocket 纯 lua 占位 (在 nginx 内桥接 ngx.socket; 满足 require("socket"))
  # 说明: luasocket 官方是 C 扩展, 此处不编译 C, 改为纯 lua 桥接 cosocket。
  echo "    - luasocket 纯 lua 桥接"
  cat > "$LUA_ROOT/socket.lua" <<'LUA'
-- 纯 lua 的 socket 兼容层 (不依赖 C 扩展)
-- 在 nginx 运行时桥接 ngx.socket.tcp()/udp(); 非 nginx 环境会明确报错。
local socket = {}

function socket.tcp()
  if ngx and ngx.socket and ngx.socket.tcp then
    return ngx.socket.tcp()
  end
  error("socket.tcp: 仅在 nginx/OpenResty 运行时可用 (cosocket)")
end

function socket.udp()
  if ngx and ngx.socket and ngx.socket.udp then
    return ngx.socket.udp()
  end
  error("socket.udp: 仅在 nginx/OpenResty 运行时可用 (cosocket)")
end

function socket.connect(host, port)
  local s = socket.tcp()
  local ok, err = s:connect(host, port)
  if not ok then error(err) end
  return s
end

return socket
LUA

  # 4.4 qist/waf 纯 lua 防火墙
  echo "    - qist/waf"
  rm -rf "$WORK/waf-tmp"
  git clone --depth=1 "$WAF_REPO" "$WORK/waf-tmp"
  # waf 顶层 lua 入口 (config.lua / lib.lua / init.lua / access.lua ...)
  cp "$WORK/waf-tmp"/*.lua "$LUA_ROOT/waf/" 2>/dev/null || true
  # 规则目录
  if [ -d "$WORK/waf-tmp/rule-config" ]; then
    cp -r "$WORK/waf-tmp/rule-config" "$LUA_ROOT/waf/rule-config"
  fi
  rm -rf "$WORK/waf-tmp"

  echo "    lua 生态安装完成 -> $LUA_ROOT"
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
    install_lua_ecosystem
    fetch_nginx_modules
    echo "==> 依赖全部就绪"
    ;;
  openssl)   prep_openssl ;;
  luajit)    build_luajit ;;
  mimalloc)  build_mimalloc ;;
  luavm)     install_lua_ecosystem ;;
  modules)   fetch_nginx_modules ;;
  *)
    echo "用法: $0 [all|openssl|luajit|mimalloc|luavm|modules|clean]"
    exit 1
    ;;
esac
