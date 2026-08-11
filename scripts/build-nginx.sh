#!/usr/bin/env bash
#
# build-nginx.sh - 完整编译 nginx (整合原 build-nginx.yml 的全部第三方模块 + lua 支持)
#
# 设计:
#   - 原 yml 里分散在各平台 step 的 ./auto/configure 参数, 全部整合到本脚本 (只增不删)
#   - CI 各 step / 本机 统一调用本脚本, 仅通过环境变量传入路径前缀, 不重复写编译参数
#   - 平台差异 (Linux / macOS) 在脚本内处理:
#       * 静态链接: Linux 用 -Wl,-Bstatic ... -Wl,-Bdynamic; macOS 用 -Wl,-force_load /path/lib.a
#       * 并发:     Linux 用 nproc; macOS 用 sysctl -n hw.ncpu
#       * 链接检查: Linux 用 ldd; macOS 用 otool -L
#
# 关键路径约定 (CI 与本机通用):
#   $ROOT            仓库根目录 (脚本上两级)
#   $WORK            = $ROOT/work  (luajit / mimalloc / lua 生态 落在此)
#   $SRC             nginx 源码目录 (CI 内通常为 $ROOT/nginx, 本机为 $WORK/nginx-$VER)
#   第三方模块目录  位于 $ROOT 下 (simplresty/ngx_devel_kit, set-misc, ..., lua-nginx-module, ndk-lua)
#   OpenSSL 源码     $ROOT/openssl-$OPENSSL_VER (nginx 用相对 ../openssl-$OPENSSL_VER)
#
# 用法:
#   ./build-nginx.sh                完整编译 (依赖已就绪)
#   PREFIX=/workspace ./build-nginx.sh   CI docker 内, 把 libs 前缀指向 /workspace
#   CLEAN_ENV=1 ./build-nginx.sh    本机绕过 safe-delete 的 rm 包装
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

# ---------- 路径 ----------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/work}"
NGINX_VER="${NGINX_VER:-1.31.3}"
OPENSSL_VER="${OPENSSL_VER:-3.6.3}"

# 第三方模块源码所在根目录 (CI docker 内为 /workspace, 直编 / macos 为 $GITHUB_WORKSPACE, 本机为 $ROOT)
MODULE_ROOT="${MODULE_ROOT:-$ROOT}"
# 依赖库 (pcre2/zlib/xz/libxml2/libxslt) 安装前缀; CI docker 用 /workspace/libs, 直编用 $GITHUB_WORKSPACE/libs
LIBS_PREFIX="${LIBS_PREFIX:-$WORK/libs}"

LUAJIT_LIB="$WORK/luajit/usr/local/lib"
LUAJIT_INC="$WORK/luajit/usr/local/include/luajit-2.1"
# mimalloc 安装路径在不同平台/版本下可能是 lib/ 或 lib64/, 且带 mimalloc-<ver> 子目录,
# 用 glob 动态定位 libmimalloc.a 所在目录, 避免硬编码 lib/ 导致 -L 找不到 .a
MIMALLOC_LIB="$(ls -d "$WORK"/mimalloc/lib*/mimalloc-2.1 2>/dev/null | head -1)"
if [ -z "$MIMALLOC_LIB" ]; then
  MIMALLOC_LIB="$(dirname "$(ls "$WORK"/mimalloc/lib*/libmimalloc.a 2>/dev/null | head -1)")"
fi
[ -z "$MIMALLOC_LIB" ] && MIMALLOC_LIB="$WORK/mimalloc/lib"
LUA_ROOT="$WORK/lua"

# nginx 源码目录: 优先用 $ROOT/nginx (CI), 否则本机 $WORK/nginx-$VER
# nginx 源码: 优先 $WORK/nginx-$NGINX_VER (官方 tarball, 自带 ./configure)
# 注: ci-setup-deps.sh 已改用 tarball, 不再创建 $ROOT/nginx
if [ -f "$WORK/nginx-$NGINX_VER/configure" ]; then
  SRC="$WORK/nginx-$NGINX_VER"
elif [ -d "$ROOT/nginx" ]; then
  SRC="$ROOT/nginx"
else
  SRC="$WORK/nginx-$NGINX_VER"
fi
echo "==> ROOT=$ROOT | WORK=$WORK | SRC=$SRC"
echo "==> MODULE_ROOT=$MODULE_ROOT | LIBS_PREFIX=$LIBS_PREFIX"

cd "$SRC"
rm -rf objs auto/autoconf.err 2>/dev/null

# ---------- 导出给 ./configure 子进程继承的环境 ----------
export WORK LUAJIT_LIB LUAJIT_INC LUA_ROOT
export PKG_CONFIG_PATH="$LIBS_PREFIX/lib/pkgconfig:$LIBS_PREFIX/lib64/pkgconfig:$LIBS_PREFIX/lib/x86_64-linux-gnu/pkgconfig:$LIBS_PREFIX/lib/aarch64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
export C_INCLUDE_PATH="$LIBS_PREFIX/include"
export LIBRARY_PATH="$LIBS_PREFIX/lib:$LIBS_PREFIX/lib64"
export PATH="$LIBS_PREFIX/bin:$PATH"
XML_LIBS="$(pkg-config --cflags --static libxml-2.0 libxslt libexslt 2>/dev/null)"
XML_LDFLAGS="$(pkg-config --libs --static libxml-2.0 libxslt libexslt 2>/dev/null)"
export CFLAGS="$XML_LIBS"
# 注意: 不能把 $XML_LDFLAGS (-lxml2 -lxslt -lz -llzma ...) 注入 LIBS/LDFLAGS 环境变量,
# 否则 ./configure 会把它们放到 ld 命令行前面且不受 -Bstatic 控制, ld 优先链到系统 /lib64 的 .so,
# 导致 ldd 看到 libxml2.so/libz.so/liblzma.so 等动态依赖.
# XML/XSLT 库只通过下方 LD_OPT 的 -Wl,-Bstatic ... -Wl,-Bdynamic 包裹静态链入.
export LDFLAGS="-L$LIBS_PREFIX/lib"

# ---------- 平台相关链接参数 (LuaJIT + mimalloc 静态编入) ----------
if [ "$PLATFORM" = "macos" ]; then
  # macOS: clang ld 不支持 -Bstatic, 用 -force_load 强制静态链入 .a
  LD_OPT="-L$LUAJIT_LIB -L$MIMALLOC_LIB -Wl,-force_load,$LUAJIT_LIB/libluajit-5.1.a -Wl,-force_load,$MIMALLOC_LIB/libmimalloc.a"
  # macOS 编译额外屏蔽若干告警
  CC_WARN="-Wno-pragma-pack -Wno-unused-but-set-variable -Wno-incompatible-pointer-types -Wno-compare-distinct-pointer-types"
else
  # Linux: -Bstatic 包住静态库, -Bdynamic 收尾
  LD_OPT="-L$LUAJIT_LIB -L$MIMALLOC_LIB -Wl,-Bstatic -lluajit-5.1 -lmimalloc -Wl,-Bdynamic"
  CC_WARN=""
fi
CC_OPT="-g -O2 -fstack-protector-strong -Wformat -Werror=format-security -Wno-deprecated-declarations -fno-strict-aliasing -D_FORTIFY_SOURCE=2 --param=ssp-buffer-size=4 -DTCP_FASTOPEN=23 -fPIC -Wno-cast-function-type $CC_WARN -I$LUAJIT_INC $XML_LIBS"
# 关键: XML/XSLT/zlib 的静态库 (libxml2.a/libxslt.a/libexslt.a/libz.a) 已编入 work/libs,
# 但 pkg-config --static 输出的 -lexslt -lxslt -lxml2 -lz 落在 -Bdynamic 之后会变成动态链接.
# 必须用 -Wl,-Bstatic 包裹, 否则 ldd 会看到 libxml2.so/libz.so 等动态依赖 (与发布版全静态不符).
# 关键: nginx 的 xslt 模块 configure 脚本(auto/lib/libxslt/conf)会用系统 pkg-config 把
#   -lxml2 -lxslt -lexslt 追加到 CORE_LIBS, 且这段在 --with-ld-opt 之后、不受下面的 -Bstatic 控制,
#   导致 ld 默认 -Bdynamic 命中系统 /lib64/libxml2.so.2 (进而拖入 libz.so.1 / liblzma.so.5).
# 修复: 这里用「绝对路径 .a」显式静态链入 xml2/xslt/exslt/z, 并加 --as-needed,
#   使 CORE_LIBS 里重复出现的 -lxml2 因符号已满足且 as-needed 而不再写入系统动态依赖.
XML_LIB_DIR="$LIBS_PREFIX/lib"
if [ "$PLATFORM" = "macos" ]; then
  # macOS 用 ld64: 不认识 --as-needed / -z relro / -Bstatic 等 GNU ld 选项,
  # 改用 -force_load 显式静态链入 xml2/xslt/exslt/z (已在上方 LD_OPT 含 luajit/mimalloc force_load)
  LD_OPT="$LD_OPT -Wl,-force_load,$XML_LIB_DIR/libexslt.a"
  LD_OPT="$LD_OPT -Wl,-force_load,$XML_LIB_DIR/libxslt.a"
  LD_OPT="$LD_OPT -Wl,-force_load,$XML_LIB_DIR/libxml2.a"
  LD_OPT="$LD_OPT -Wl,-force_load,$XML_LIB_DIR/libz.a"
else
  # Linux: 用 -Bstatic 包裹静态库, -Bdynamic 收尾 (避免命中系统 .so)
  LD_OPT="$LD_OPT -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,-Bstatic"
  LD_OPT="$LD_OPT $XML_LIB_DIR/libexslt.a $XML_LIB_DIR/libxslt.a $XML_LIB_DIR/libxml2.a $XML_LIB_DIR/libz.a"
  LD_OPT="$LD_OPT -Wl,-Bdynamic -lm"
fi

# ---------- 补丁 (nginx_upstream_check_module 对 nginx 1.20.1+ 的 patch) ----------
# 注意:
#   1) patch 会给 nginx 核心 (src/http/ngx_http_upstream.c) 注入 upsync 依赖的
#      ngx_http_upstream_check_add/delete_dynamic_peer 符号, 必须成功打上, 否则链接 upsync 报 undefined reference
#   2) 幂等: 用 -R --dry-run 判断是否已应用; 已应用则跳过, 未应用才打 (不能用正向 dry-run 失败当"跳过",
#      因为 patch 对 nginx 1.31.3 需要 --fuzz, 正向 dry-run 可能误报 Reversed)
if [ -d "$MODULE_ROOT/nginx_upstream_check_module" ]; then
  PATCH_FILE="$MODULE_ROOT/nginx_upstream_check_module/check_1.20.1+.patch"
  if [ -f "$PATCH_FILE" ]; then
    if patch -p1 -R --fuzz=5 --dry-run < "$PATCH_FILE" >/dev/null 2>&1; then
      echo "==> nginx_upstream_check patch 已应用, 跳过"
    else
      echo "==> 应用 nginx_upstream_check patch (fuzz)"
      patch -p1 --fuzz=5 < "$PATCH_FILE"
    fi
  fi
fi

# ---------- configure (整合 yml 全部模块, 只增不删) ----------
echo "==> configure nginx ($PLATFORM)"
./configure \
  --prefix= \
  --conf-path=conf/nginx.conf \
  --pid-path=logs/nginx.pid \
  --http-log-path=logs/access.log \
  --error-log-path=logs/error.log \
  --sbin-path=nginx \
  --http-client-body-temp-path=temp/client_body_temp \
  --http-proxy-temp-path=temp/proxy_temp \
  --http-fastcgi-temp-path=temp/fastcgi_temp \
  --http-scgi-temp-path=temp/scgi_temp \
  --http-uwsgi-temp-path=temp/uwsgi_temp \
  --user=nginx \
  --group=nginx \
  --with-compat \
  --with-pcre="$MODULE_ROOT/pcre2" \
  --with-zlib="$MODULE_ROOT/zlib" \
  --with-pcre-jit \
  --with-http_ssl_module \
  --with-http_stub_status_module \
  --with-http_realip_module \
  --with-http_auth_request_module \
  --with-http_addition_module \
  --with-http_gzip_static_module \
  --with-http_sub_module \
  --with-http_v2_module \
  --with-stream \
  --with-debug \
  --with-stream_ssl_module \
  --with-stream_realip_module \
  --with-stream_ssl_preread_module \
  --with-threads \
  --with-http_secure_link_module \
  --with-http_gunzip_module \
  --with-http_dav_module \
  --with-http_flv_module \
  --with-http_mp4_module \
  --with-http_random_index_module \
  --with-http_slice_module \
  --with-mail \
  --with-mail_ssl_module \
  --with-file-aio \
  --with-http_v3_module \
  --with-http_xslt_module \
  --with-openssl-opt=enable-tls1_3 \
  --with-openssl="$MODULE_ROOT/openssl-$OPENSSL_VER" \
  --add-module="$MODULE_ROOT/ngx_devel_kit" \
  --add-module="$MODULE_ROOT/set-misc-nginx-module" \
  --add-module="$MODULE_ROOT/ngx_http_substitutions_filter_module" \
  --add-module="$MODULE_ROOT/nginx-http-auth-digest" \
  --add-module="$MODULE_ROOT/nginx_upstream_check_module" \
  --add-module="$MODULE_ROOT/ngx_cache_purge" \
  --add-module="$MODULE_ROOT/nginx-upsync-module" \
  --add-module="$MODULE_ROOT/echo-nginx-module" \
  --add-module="$MODULE_ROOT/mod_zip" \
  --add-module="$MODULE_ROOT/nginx-upstream-dynamic-servers" \
  --add-module="$MODULE_ROOT/headers-more-nginx-module" \
  --add-module="$MODULE_ROOT/nginx-module-vts" \
  --add-module="$MODULE_ROOT/nginx-dav-ext-module" \
  --add-module="$MODULE_ROOT/ngx_brotli" \
  --add-module="$MODULE_ROOT/ngx-fancyindex" \
  --add-module="$MODULE_ROOT/nginx-module-sts" \
  --add-module="$MODULE_ROOT/nginx-module-stream-sts" \
  --add-module="$MODULE_ROOT/lua-nginx-module" \
  --add-module="$MODULE_ROOT/stream-lua-nginx-module" \
  --add-module="$MODULE_ROOT/lua-upstream-nginx-module" \
  --with-cc-opt="$CC_OPT" \
  --with-ld-opt="$LD_OPT"

# ---------- 确保 NDK 的 ndk_config.h 已生成 ----------
# 现象: vision5/ngx_devel_kit 的 config 脚本仅定义 ndk_generate_files() 却偶发不调用,
#       导致 ./configure 阶段可能不生成 ndk_config.h, make 时 ndk.h 报 "No such file or directory"。
# 这里在 configure 结束后强制用 NDK 自带的 auto/build 生成, 输出到 nginx objs 的 addon/ndk
# (ndk.h 的 #include <ndk_config.h> 搜索路径之一), 同时复制到 NDK 自己的 objs 作为兜底。
if [ -d "$MODULE_ROOT/ngx_devel_kit" ] && [ -f "$MODULE_ROOT/ngx_devel_kit/auto/build" ]; then
  echo "==> 预生成 NDK ndk_config.h"
  NDK_OUT="$SRC/objs/addon/ndk"
  mkdir -p "$NDK_OUT" "$MODULE_ROOT/ngx_devel_kit/objs"
  # auto/build 第1个参数必须是 nginx 源码根目录 ($SRC), 第2个为输出目录 (绝对路径)
  bash "$MODULE_ROOT/ngx_devel_kit/auto/build" "$SRC" "$NDK_OUT" \
    || { echo "    [!] ndk_config.h 生成失败"; exit 1; }
  cp -f "$NDK_OUT/ndk_config.h" "$MODULE_ROOT/ngx_devel_kit/objs/ndk_config.h" 2>/dev/null || true
  echo "    ndk_config.h: $(ls "$NDK_OUT/ndk_config.h")"
else
  echo "    [!] 未找到 ngx_devel_kit/auto/build, 跳过 ndk_config.h 预生成"
fi

# ---------- 编译 ----------
echo "==> make -j$NPROC"
if [ "${CLEAN_ENV:-0}" = "1" ]; then
  env -i PATH=/usr/bin:/bin:/usr/local/bin:/usr/sbin:/sbin \
          HOME="$HOME" CC="${CC:-gcc}" CXX="${CXX:-g++}" \
          PKG_CONFIG_PATH="$PKG_CONFIG_PATH" C_INCLUDE_PATH="$C_INCLUDE_PATH" \
          LIBRARY_PATH="$LIBRARY_PATH" LDFLAGS="$LDFLAGS" CFLAGS="$CFLAGS" LIBS="$LIBS" \
          MAKEFLAGS="-j$NPROC" make
else
  make -j"$NPROC"
fi

echo "==> 二进制: $SRC/objs/nginx"
echo "==> 链接检查:"
LDD objs/nginx | grep -E "ssl|crypto|luajit|mimalloc" && echo "    ⚠️ 仍有动态依赖" || echo "    ✅ 全部静态编入"

# 提示 lua_package_path 配置
echo
echo "==> nginx.conf 需包含:"
echo "   lua_package_path \"$LUA_ROOT/?.lua;$LUA_ROOT/?/init.lua;$LUA_ROOT/waf/?.lua;$LUAJIT_LIB/../share/lua/5.1/?.lua;;\";"
echo "   # WAF 挂载示例:"
echo "   #   init_by_lua_file $LUA_ROOT/waf/init.lua;"
echo "   #   access_by_lua_file $LUA_ROOT/waf/access.lua;"
