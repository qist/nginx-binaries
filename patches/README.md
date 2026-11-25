# nginx 源码补丁

本目录存放随打包编译进 nginx 的源码补丁。所有补丁都要求**干净应用**（`patch -p1 --fuzz=0`），
失败即中止构建，不允许产出“缺特性”的二进制。

## 补丁列表

| 补丁 | 作用 | 已验证 nginx 版本 |
|---|---|---|
| `nginx-stream-pp-var.patch` | `proxy_protocol` 支持变量（保留 `on/off/v2` 字面量），用于 `ssl_preread + map + proxy_pass $backend` 按 SNI 给不同后端发 v1 / v2 / 不发 | 1.31.9（最低 1.31.4） |

> **最低版本 1.31.4**：PROXY protocol **v2 写入**（`ngx_proxy_protocol_v2_write`）和
> `proxy_protocol v2` 指令都是 1.31.4 引入的。1.31.3 只有 v1/on/off，且写入函数签名不同，
> 本补丁无法应用；确需构建 1.31.3 时用 `ALLOW_UNPATCHED=1` 跳过补丁（产物无该特性，
> 面板必须按能力标记回退）。

### nginx-stream-pp-var.patch

**背景**：官方 `proxy_protocol` 只接受 `on`（v1）、`off`、`v2` 字面量，是 server 级静态开关。
同一 `listen 443` 上，xray 需要 PROXY protocol、sing-box REALITY 不能收，官方无法按 SNI 区分。

**新增语义**：

```nginx
map $ssl_preread_server_name $backend {
    x.example.com backend_x;
    y.example.com backend_y;
    default       backend_x;
}
map $ssl_preread_server_name $pp_ver {
    x.example.com v2;
    y.example.com off;
    default       off;
}

server {
    listen 443;
    ssl_preread on;
    proxy_pass $backend;
    proxy_protocol $pp_ver;   # 本补丁新增；on/off/v2 字面量保持原行为
}
```

- 变量在**每个客户端会话只解析一次**（缓存在 `ngx_stream_upstream_t`），
  `proxy_next_upstream` 重试沿用同一策略；不进入数据转发热路径；
- 只接受 `on|v1|v2|off`（**大小写不敏感**，与官方枚举行为一致），其他值拒绝连接并写 error 日志（fail-closed）；
- **静态值**（不含 `$`）只允许上述白名单，非法值在 `nginx -t` 阶段直接报 `invalid value`；
  只有包含 `$` 的表达式才会编译为变量，避免“配置能过、第一个连接才失败”；
- 仅对 TCP 生效；UDP 没有 PROXY protocol 语义；
- 改动两个文件：`src/stream/ngx_stream_proxy_module.c`（解析/求值）和
  `src/stream/ngx_stream_upstream.h`（会话缓存 3 个 bit）；不改 upstream 选择/转发逻辑、
  不改 PP 编码、不改 SSL 握手顺序。

**能力标记**：构建脚本会加 `-DNGX_STREAM_PP_VAR`，可用

```bash
nginx -V 2>&1 | grep -q NGX_STREAM_PP_VAR && echo supported
```

判断二进制是否带该特性；面板生成配置前应先检查，没有标记就回退旧行为，禁止生成
`proxy_protocol $var`（否则 `nginx -t` 直接失败）。

**升级 nginx 的流程**：

1. 下载新版本源码，`patch -p1 --fuzz=0 --dry-run < patches/nginx-stream-pp-var.patch`；
2. 失败 → 手工前移补丁（结构体字段、指令表、`ngx_stream_proxy_connect` 三处），提交新补丁并更新上表；
3. 成功 → 构建后必须通过 `tests/stream_pp_var.sh`（v2 / v1 / off 首包断言）；
4. 两者都通过才允许发布。

**回滚**：移除补丁与 `-DNGX_STREAM_PP_VAR` 即可回到官方行为；此时面板必须同步回退配置生成
（整组 PP 或跳过 sing-box SNI 规则），不能让存量配置继续引用 `$var`。
