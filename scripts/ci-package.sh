#!/usr/bin/env bash
#
# ci-package.sh - 打包 nginx 产物 (二进制 + conf + 纯 lua 生态 + waf 配置示例)
#
# 用法: ci-package.sh <root> <version> <suffix> [tar.gz|zip]
#   root    : 仓库根 (CI 内 docker=/workspace, direct/macOS=$GITHUB_WORKSPACE)
#   version : nginx 版本
#   suffix  : 平台后缀 (如 glibc_amd64)
#
set -e
ROOT="$1"
VER="$2"
SUFFIX="$3"
FMT="${4:-tar.gz}"
WORK="$ROOT/work"

# nginx 二进制位置: CI 用 <root>/nginx, 本地用 <root>/work/nginx-<ver>
NGX="$ROOT/nginx"
if [ ! -f "$NGX/objs/nginx" ] && [ ! -f "$NGX/objs/nginx.exe" ]; then
  NGX="$WORK/nginx-$VER"
fi
if [ ! -f "$NGX/objs/nginx" ] && [ ! -f "$NGX/objs/nginx.exe" ]; then
  echo "ERROR: 找不到 nginx 二进制 ($NGX/objs/nginx)"
  exit 1
fi

OUT="/tmp/nginx"
rm -rf "$OUT"
mkdir -p "$OUT/logs" \
  "$OUT/temp/client_body_temp" "$OUT/temp/proxy_temp" \
  "$OUT/temp/fastcgi_temp" "$OUT/temp/scgi_temp" "$OUT/temp/uwsgi_temp"

if [ -f "$NGX/objs/nginx" ]; then
  cp "$NGX/objs/nginx" "$OUT/nginx"
elif [ -f "$NGX/objs/nginx.exe" ]; then
  cp "$NGX/objs/nginx.exe" "$OUT/nginx.exe"
fi
cp -R "$NGX/conf" "$OUT/conf"
cp -R "$NGX/docs/html" "$OUT/html" 2>/dev/null || true

# 纯 lua 生态 + waf
if [ -d "$WORK/lua" ]; then
  cp -R "$WORK/lua" "$OUT/lua"
fi
mkdir -p "$OUT/luajit-share"
if [ -d "$WORK/luajit/usr/local/share/lua" ]; then
  cp -R "$WORK/luajit/usr/local/share/lua" "$OUT/luajit-share/lua"
fi

# waf / lua 配置示例
if [ -f "$ROOT/config/nginx.quic.lua.conf" ]; then
  cp "$ROOT/config/nginx.quic.lua.conf" "$OUT/conf/nginx.quic.lua.conf"
fi

cd /tmp
if [ "$FMT" = "zip" ]; then
  zip -r "$ROOT/nginx_${VER}_${SUFFIX}.zip" nginx/
else
  tar czf "$ROOT/nginx_${VER}_${SUFFIX}.tar.gz" nginx/
fi
echo "==> 打包完成: $ROOT/nginx_${VER}_${SUFFIX}.$FMT"
