#!/usr/bin/env bash
#
# stream_pp_var.sh — 验证 nginx stream 的 proxy_protocol 支持变量（本题补丁）。
#
# 用法: ./stream_pp_var.sh /path/to/nginx
#
# 需要: python3（CI runner / 本机均有；CentOS7 构建容器可能没有 -> 调用方应跳过）
#
# 验证三件事（同一份配置里，按连接变量决定）:
#   v2  -> 后端首包以 PROXY v2 二进制签名 0d0a0d0a000d0a515549540a 开头
#   on  -> 后端首包是 "PROXY TCP4 ..." 文本
#   off -> 后端首包就是业务数据，没有 PP 头
#
set -euo pipefail

NGINX_BIN="${1:?用法: stream_pp_var.sh /path/to/nginx}"
[ -x "$NGINX_BIN" ] || { echo "!! nginx 不可执行: $NGINX_BIN" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "!! 需要 python3" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# lua-nginx-module 版 nginx 启动时会 require('resty.core')，默认搜索路径含
# 相对路径 ./resty/core.lua：把启动时的 CWD 切到随包提供的 lua 目录即可命中。
# 找不到就明确失败，不允许“跳过冒烟”把没验证过的二进制发出去。
LUA_DIR=""
if "$NGINX_BIN" -V 2>&1 | grep -q "lua-nginx-module"; then
  for d in "$ROOT/work/lua" "$ROOT/lua" "$ROOT/../lua-resty-core/lib"; do
    if [ -f "$d/resty/core.lua" ]; then LUA_DIR="$d"; break; fi
  done
  if [ -z "$LUA_DIR" ]; then
    echo "!! nginx 含 lua-nginx-module 但找不到 resty/core.lua（试过 $ROOT/work/lua 等）" >&2
    echo "   没有它 nginx 启动即失败，无法验证；请检查构建机 lua 目录布局" >&2
    exit 1
  fi
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ngx-pp-var.XXXXXX")"
# 动态取 20 个空闲端口，避免 CI 并行/本机占用导致 flaky
read -r P_V2 B_V2 P_V1 B_V1 P_OFF B_OFF P_LON B_LON P_LV2 B_LV2 P_RETRY B_RETRY B_DOWN \
        P_SNI B_SNI B_SNIOFF P_SSL B_SSL P_BAD B_BAD < <(python3 - <<'PY'
import socket
ports = []
for _ in range(20):
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    ports.append(s.getsockname()[1])
    s.close()
print(*ports)
PY
)

BACK_PIDS=()
cleanup() {
  "$NGINX_BIN" -p "$TMP" -c conf/nginx.conf -s stop >/dev/null 2>&1 || true
  for pid in "${BACK_PIDS[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

# macOS / 慢机器上 python 起监听可能超过固定 sleep：逐个等端口真的 listen。
wait_listen() {
  local port=$1
  for _ in $(seq 1 80); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      exec 3<&- 2>/dev/null || true
      return 0
    fi
    sleep 0.1
  done
  return 1
}

mkdir -p "$TMP/conf" "$TMP/logs"

cat > "$TMP/backend.py" <<'PY'
import socket, sys, threading
port = int(sys.argv[1]); out = sys.argv[2]
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(8)
def serve():
    while True:
        try:
            c, _ = s.accept()
        except OSError:
            return
        try:
            c.settimeout(3)
            data = c.recv(256)
            with open(out, "wb") as f:
                f.write(data)
        except Exception:
            pass
        finally:
            c.close()
threading.Thread(target=serve, daemon=True).start()
threading.Event().wait()
PY

cat > "$TMP/conf/nginx.conf" <<EOF
worker_processes 1;
# 官方打包的二进制 configure 时带 --user=nginx；CI runner / 本地没有该用户时
# 以 root 启动会 getpwnam 失败。测试显式降为 root（非 root 运行时该指令被忽略）。
user root;
error_log logs/error.log info;
pid logs/nginx.pid;
events { worker_connections 64; }
stream {
    map \$remote_addr \$pp_v2  { default V2; }
    map \$remote_addr \$pp_v1  { default ON; }
    map \$remote_addr \$pp_off { default OFF; }

    server { listen 127.0.0.1:$P_V2;  proxy_pass 127.0.0.1:$B_V2;  proxy_protocol \$pp_v2; }
    server { listen 127.0.0.1:$P_V1;  proxy_pass 127.0.0.1:$B_V1;  proxy_protocol \$pp_v1; }
    server { listen 127.0.0.1:$P_OFF; proxy_pass 127.0.0.1:$B_OFF; proxy_protocol \$pp_off; }

    # 向后兼容：原始字面量写法（大小写不敏感）必须保持原行为
    server { listen 127.0.0.1:$P_LON; proxy_pass 127.0.0.1:$B_LON; proxy_protocol ON; }
    server { listen 127.0.0.1:$P_LV2; proxy_pass 127.0.0.1:$B_LV2; proxy_protocol V2; }

    # 重试场景：第一台上游连接失败，next_upstream 换到第二台，
    # 缓存的 PP 策略必须继续生效（不能退化成 off）。
    upstream retry_up {
        server 127.0.0.1:$B_DOWN;
        server 127.0.0.1:$B_RETRY;
    }
    server {
        listen 127.0.0.1:$P_RETRY;
        proxy_pass retry_up;
        proxy_protocol \$pp_v2;
        proxy_next_upstream on;
        proxy_next_upstream_tries 2;
    }

    # SNI 场景（真实用法）：同一个 443 按 \$ssl_preread_server_name 选后端与策略。
    map \$ssl_preread_server_name \$sni_backend {
        a.example.com 127.0.0.1:$B_SNI;
        b.example.com 127.0.0.1:$B_SNIOFF;
        default       127.0.0.1:$B_SNI;
    }
    map \$ssl_preread_server_name \$sni_pp {
        a.example.com v2;
        b.example.com off;
        default       off;
    }
    server {
        listen 127.0.0.1:$P_SNI;
        ssl_preread on;
        proxy_pass \$sni_backend;
        proxy_protocol \$sni_pp;
    }

EOF

# proxy_ssl 需要 nginx 编译了 --with-stream_ssl_module；官方打包默认开启，
# 但本地最小构建可能没有 -> 此时跳过该场景，不影响其它断言。
STREAM_SSL=0
if "$NGINX_BIN" -V 2>&1 | grep -q -- '--with-stream_ssl_module'; then
  STREAM_SSL=1
  cat >> "$TMP/conf/nginx.conf" <<EOF

    # proxy_ssl：PP 头必须早于发往上游的 TLS ClientHello。
    server {
        listen 127.0.0.1:$P_SSL;
        proxy_pass 127.0.0.1:$B_SSL;
        proxy_ssl on;
        proxy_ssl_verify off;
        proxy_protocol \$pp_v2;
    }
EOF
fi

cat >> "$TMP/conf/nginx.conf" <<EOF

    # 变量返回非法值：连接必须失败，且日志要带具体值。
    map \$remote_addr \$pp_bad { default bogus; }
    server {
        listen 127.0.0.1:$P_BAD;
        proxy_pass 127.0.0.1:$B_BAD;
        proxy_protocol \$pp_bad;
    }
}
EOF

# 先做配置检查：未打补丁的原生 nginx 会在这里报 invalid value "$pp_v2"
if ! "$NGINX_BIN" -p "$TMP" -c conf/nginx.conf -t >"$TMP/conf-test.log" 2>&1; then
  echo "!! nginx -t 失败（补丁未生效？）" >&2
  cat "$TMP/conf-test.log" >&2
  exit 1
fi

# 静态非法值必须在配置阶段就报错（不能等到第一个连接才失败）
cat > "$TMP/conf/bad.conf" <<EOF
worker_processes 1;
user root;
events { worker_connections 8; }
stream {
    server { listen 127.0.0.1:1; proxy_pass 127.0.0.1:2; proxy_protocol invalid; }
}
EOF
if "$NGINX_BIN" -p "$TMP" -c conf/bad.conf -t >"$TMP/bad-test.log" 2>&1; then
  echo "!! proxy_protocol invalid 没有被 nginx -t 拒绝" >&2
  exit 1
fi
if ! grep -q "invalid value" "$TMP/bad-test.log"; then
  echo "!! 非法静态值报错信息不符合预期:" >&2
  cat "$TMP/bad-test.log" >&2
  exit 1
fi

for pair in "$B_V2:$TMP/out_v2.bin" "$B_V1:$TMP/out_v1.bin" "$B_OFF:$TMP/out_off.bin" \
            "$B_LON:$TMP/out_lon.bin" "$B_LV2:$TMP/out_lv2.bin" \
            "$B_RETRY:$TMP/out_retry.bin" \
            "$B_SNI:$TMP/out_sni_v2.bin" "$B_SNIOFF:$TMP/out_sni_off.bin" \
            "$B_SSL:$TMP/out_ssl.bin" "$B_BAD:$TMP/out_bad.bin"; do
  port="${pair%%:*}"; out="${pair#*:}"
  python3 "$TMP/backend.py" "$port" "$out" &
  BACK_PIDS+=("$!")
done
for port in "$B_V2" "$B_V1" "$B_OFF" "$B_LON" "$B_LV2" "$B_RETRY" \
            "$B_SNI" "$B_SNIOFF" "$B_SSL"; do
  wait_listen "$port" || { echo "!! 后端未就绪: $port" >&2; exit 1; }
done

( cd "${LUA_DIR:-$PWD}" && "$NGINX_BIN" -p "$TMP" -c conf/nginx.conf )
wait_listen "$P_V2" || { echo "!! nginx 未监听 $P_V2" >&2; tail -20 "$TMP/logs/error.log" >&2 2>/dev/null; exit 1; }

python3 - "$P_V2" "$P_V1" "$P_OFF" "$P_LON" "$P_LV2" "$P_RETRY" <<'PY'
import socket, sys, time
marker = b"ngx-pp-var-smoke"

def connect(port, tries=50):
    last = None
    for _ in range(tries):
        try:
            return socket.create_connection(("127.0.0.1", port), timeout=3)
        except OSError as e:
            last = e
            time.sleep(0.1)
    raise last

for port in map(int, sys.argv[1:]):
    s = connect(port)
    s.sendall(marker)
    s.close()
time.sleep(0.8)
PY

# SNI：同一个监听端口，按 servername 命中不同策略；后端不是 TLS，握手会失败，
# 但首包已经写出，足以断言 PP 头。
# proxy_ssl：nginx 会先发 PP 再开始 TLS 握手，后端只需记录首包。
# 非法变量：连接会被直接 finalize（客户端侧表现为读完即断）。
python3 - "$P_SNI" "$P_SSL" "$P_BAD" "$STREAM_SSL" <<'PY'
import socket, ssl, sys, time

sni_port, ssl_port, bad_port, stream_ssl = map(int, sys.argv[1:])

def tls_probe(port, server_name):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    raw = socket.create_connection(("127.0.0.1", port), timeout=3)
    raw.settimeout(3)
    try:
        ctx.wrap_socket(raw, server_hostname=server_name)
    except Exception:
        pass
    finally:
        try:
            raw.close()
        except Exception:
            pass

tls_probe(sni_port, "a.example.com")
tls_probe(sni_port, "b.example.com")

# proxy_ssl：发一段业务数据触发 nginx 连接上游
if stream_ssl:
    s = socket.create_connection(("127.0.0.1", ssl_port), timeout=3)
    s.sendall(b"ngx-pp-var-smoke")
    s.close()

# 非法变量：连接应立即被关闭
s = socket.create_connection(("127.0.0.1", bad_port), timeout=3)
s.sendall(b"ngx-pp-var-smoke")
s.close()

time.sleep(1.0)
PY

python3 - "$TMP" "$STREAM_SSL" <<'PY'
import sys, os, time
tmp = sys.argv[1]
stream_ssl = sys.argv[2] == "1"
def wait_read(name):
    path = os.path.join(tmp, name)
    for _ in range(50):
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return open(path, "rb").read()
        time.sleep(0.1)
    raise SystemExit(f"!! 后端未收到数据: {name}")

v2 = wait_read("out_v2.bin")
v1 = wait_read("out_v1.bin")
off = wait_read("out_off.bin")
lon = wait_read("out_lon.bin")
lv2 = wait_read("out_lv2.bin")
retry = wait_read("out_retry.bin")
sni_v2 = wait_read("out_sni_v2.bin")
sni_off = wait_read("out_sni_off.bin")
ssl_first = wait_read("out_ssl.bin") if stream_ssl else b""

fail = []
if not v2.startswith(b"\r\n\r\n\x00\r\nQUIT\n"):
    fail.append("v2 首包不是 PROXY v2 签名: %r" % v2[:24])
if not (v1.startswith(b"PROXY TCP4 ") or v1.startswith(b"PROXY TCP6 ")):
    fail.append("v1 首包不是 PROXY 文本头: %r" % v1[:32])
if not off.startswith(b"ngx-pp-var-smoke"):
    fail.append("off 不应有 PP 头: %r" % off[:32])
if not (lon.startswith(b"PROXY TCP4 ") or lon.startswith(b"PROXY TCP6 ")):
    fail.append("字面量 on 首包不是 PROXY 文本头: %r" % lon[:32])
if not lv2.startswith(b"\r\n\r\n\x00\r\nQUIT\n"):
    fail.append("字面量 v2 首包不是 PROXY v2 签名: %r" % lv2[:24])
if not retry.startswith(b"\r\n\r\n\x00\r\nQUIT\n"):
    fail.append("next_upstream 重试后 PP 策略丢失: %r" % retry[:24])
if not sni_v2.startswith(b"\r\n\r\n\x00\r\nQUIT\n"):
    fail.append("SNI=a 未按 map 发送 v2: %r" % sni_v2[:24])
if sni_off.startswith(b"PROXY ") or sni_off.startswith(b"\r\n\r\n"):
    fail.append("SNI=b 不应有 PP 头: %r" % sni_off[:24])
if not sni_off.startswith(b"\x16\x03"):
    fail.append("SNI=b 首包不是 TLS ClientHello: %r" % sni_off[:16])
if stream_ssl and not ssl_first.startswith(b"\r\n\r\n\x00\r\nQUIT\n"):
    fail.append("proxy_ssl 场景 PP 未先于 TLS 发送: %r" % ssl_first[:24])

# 非法变量：不应建立上游连接，且日志必须带具体值
import os, re
bad_out = os.path.join(tmp, "out_bad.bin")
if os.path.exists(bad_out) and os.path.getsize(bad_out) > 0:
    fail.append("非法变量仍连到了后端: %r" % open(bad_out, "rb").read()[:24])

log_path = os.path.join(tmp, "logs", "error.log")
log_text = open(log_path, "rb").read().decode("utf-8", "replace") if os.path.exists(log_path) else ""
if 'invalid proxy_protocol value "bogus"' not in log_text:
    fail.append("日志未记录非法变量值: %r" % log_text[-300:])

if fail:
    for f in fail:
        print("!! " + f, file=sys.stderr)
    tail_log = log_text.strip().splitlines()[-15:]
    if tail_log:
        print("--- nginx error.log (tail) ---", file=sys.stderr)
        print("\n".join(tail_log), file=sys.stderr)
    raise SystemExit(1)

tail = "proxy_ssl ordering" if stream_ssl else "proxy_ssl SKIPPED (no --with-stream_ssl_module)"
print("PASS proxy_protocol variable: v2/v1/off, literal on/v2, retry cached, "
      f"SNI map, {tail}, invalid value rejected")
PY
