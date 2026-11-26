#!/usr/bin/env bash
# install-lua-ecosystem.sh - 安装纯 lua 生态 (resty-* + dkjson + cjson 垫片 + socket 桥 + waf)
#
# 全部为纯 lua 文件拷贝, 不编译任何 C 扩展 (lua-cjson 用纯 lua 垫片、luasocket 用
# cosocket 桥接) —— Linux / Windows / macOS 构建共用此单一代码路径:
#   * Linux:  build-libs.sh 调用 (LUA_ROOT=$WORK/lua)
#   * Windows: build-nginx.yml Windows step 直接调用 (LUA_ROOT=$PWD/lua)
#
# 用法: install-lua-ecosystem.sh <LUA_ROOT>
set -eu

LUA_ROOT="${1:?用法: install-lua-ecosystem.sh <LUA_ROOT>}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lua-eco.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

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
WAF_REPO="https://github.com/qist/nginxguard.git"

mkdir -p "$LUA_ROOT/resty" "$LUA_ROOT/waf"

# 1. resty-* 生态: 复制各仓库 lib/ 下的 lua 文件
for repo in "${RESTY_LIBS[@]}"; do
  name="$(basename "$repo" .git)"
  echo "    - $name"
  git clone --depth=1 --quiet "$repo" "$WORK/$name-tmp"
  if [ -d "$WORK/$name-tmp/lib/resty" ]; then
    cp -r "$WORK/$name-tmp/lib/resty/." "$LUA_ROOT/resty/" 2>/dev/null || true
  fi
  if [ -d "$WORK/$name-tmp/lib" ]; then
    cp -r "$WORK/$name-tmp/lib/." "$LUA_ROOT/" 2>/dev/null || true
  fi
done

# 2. dkjson (纯 lua JSON) + cjson 垫片 (满足 waf 的 require("cjson"))
echo "    - dkjson + cjson 垫片"
git clone --depth=1 --quiet "$DKJSON_REPO" "$WORK/dkjson-tmp"
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

# 3. luasocket 纯 lua 占位 (在 nginx 内桥接 ngx.socket; 满足 require("socket"))
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

# 4. qist/waf 纯 lua 防火墙
echo "    - qist/waf"
git clone --depth=1 --quiet "$WAF_REPO" "$WORK/waf-tmp"
cp "$WORK/waf-tmp"/*.lua "$LUA_ROOT/waf/" 2>/dev/null || true
if [ -d "$WORK/waf-tmp/rule-config" ]; then
  cp -r "$WORK/waf-tmp/rule-config" "$LUA_ROOT/waf/rule-config"
fi

echo "==> lua 生态安装完成 -> $LUA_ROOT"
