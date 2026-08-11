# nginx-binaries

自动构建多平台 nginx 二进制包的 GitHub Actions 工作流。

## 功能特性

- ✅ **自动检测新版本** - 每天自动检查 nginx 官方仓库的最新版本
- ✅ **增量构建** - 只对新发布的版本进行构建，避免重复工作
- ✅ **多平台支持** - 覆盖主流操作系统和架构
- ✅ **丰富的模块** - 包含常用的第三方 nginx 模块
- ✅ **HTTP/3 支持** - 基于 OpenSSL 3.6.3 + nginx 原生 `--with-http_v3_module`，支持 QUIC/HTTP3

## 支持的平台

| 操作系统 / libc | 架构 | 包名格式 |
|----------|------|----------|
| glibc (Ubuntu/Debian/Red Hat/CentOS) | amd64 | `nginx_{version}_glibc_amd64.tar.gz` |
| glibc (Ubuntu/Debian/Red Hat/CentOS) | arm64 | `nginx_{version}_glibc_arm64.tar.gz` |
| musl (Alpine / OpenWrt) | amd64 | `nginx_{version}_musl_amd64.tar.gz` |
| musl (Alpine / OpenWrt) | arm64 | `nginx_{version}_musl_arm64.tar.gz` |
| macOS | amd64 | `nginx_{version}_macos_amd64.tar.gz` |
| macOS | arm64 | `nginx_{version}_macos_arm64.tar.gz` |
| Windows | amd64 | `nginx_{version}_windows_amd64.zip` |

## 编译的模块

### 核心模块
- `--with-compat` - 兼容模式
- `--with-pcre-jit` - PCRE2 JIT 支持
- `--with-http_ssl_module` - SSL/TLS 支持
- `--with-http_v2_module` - HTTP/2 支持
- `--with-http_v3_module` - HTTP/3 (QUIC) 支持
- `--with-http_stub_status_module` - 状态页
- `--with-http_realip_module` - 真实客户端 IP
- `--with-http_auth_request_module` - 子请求鉴权
- `--with-http_addition_module` - 响应内容添加
- `--with-http_gzip_static_module` - gzip 静态预压缩
- `--with-http_sub_module` - 字符串替换
- `--with-http_secure_link_module` - 安全链接
- `--with-http_gunzip_module` - 客户端 gunzip
- `--with-http_dav_module` - WebDAV
- `--with-http_flv_module` - FLV 流媒体
- `--with-http_mp4_module` - MP4 流媒体
- `--with-http_random_index_module` - 随机首页
- `--with-http_slice_module` - 切片（断点续传/范围）
- `--with-http_xslt_module` - XSLT 转换
- `--with-file-aio` - 异步文件 I/O
- `--with-threads` - 线程池
- `--with-stream` - TCP/UDP 流模块
- `--with-stream_ssl_module` - 流 SSL
- `--with-stream_realip_module` - 流真实 IP
- `--with-stream_ssl_preread_module` - 流 SSL 预读（SNI/ALPN 分流）
- `--with-mail` - mail 代理模块
- `--with-mail_ssl_module` - mail SSL
- `--with-debug` - 调试日志
- `--with-openssl-opt=enable-tls1_3` - 启用 TLS 1.3

> 注：HTTP/3 由 nginx 原生 `--with-http_v3_module` + OpenSSL 3.x 提供，无需 QuicTLS。

### 第三方模块
- `ngx_devel_kit` (NDK) - 基础开发工具集（其它 Lua 模块的前置依赖）
- `set-misc-nginx-module` - 变量处理/编码工具
- `ngx_http_substitutions_filter_module` - 响应内容正则替换
- `nginx-http-auth-digest` - HTTP Digest 认证
- `nginx_upstream_check_module` - 上游健康检查
- `ngx_cache_purge` - 缓存清除
- `nginx-upsync-module` - 基于 consul/etcd 的动态上游
- `echo-nginx-module` - 响应内容输出
- `mod_zip` - 动态 ZIP 打包
- `nginx-upstream-dynamic-servers` - 动态上游服务器
- `headers-more-nginx-module` - 自定义请求/响应头
- `nginx-module-vts` - 虚拟主机流量状态
- `nginx-dav-ext-module` - WebDAV 扩展方法（PROPFIND/LOCK 等）
- `ngx_brotli` - Brotli 压缩
- `ngx-fancyindex` - 美观的目录索引
- `nginx-module-sts` - 流流量状态（stream vts）
- `nginx-module-stream-sts` - 流模块状态监控
- `lua-nginx-module` - Lua 脚本支持（基于 LuaJIT）
- `stream-lua-nginx-module` - 流模块 Lua 脚本支持
- `lua-upstream-nginx-module` - 上游 Lua 管理接口

### 内置 Lua 生态（静态编入，无需运行时安装）
- **LuaJIT 2.1**（openresty/luajit2，静态库 + FFI）
- **mimalloc 2.1.9**（静态库，`MI_OVERRIDE` 模式接管 malloc/free）
- **lua-resty-core** 及全套 resty 生态：
  - `lua-resty-lrucache` / `lua-resty-memcached` / `lua-resty-mysql` / `lua-resty-redis`
  - `lua-resty-dns` / `lua-resty-upload` / `lua-resty-websocket` / `lua-resty-lock`
  - `lua-resty-logger-socket`(cloudflare) / `lua-resty-string` / `lua-resty-cookie`(cloudflare)
  - `lua-resty-http`(ledgetech) / `lua-resty-ipmatcher`(api7) / `lua-resty-global-throttle`
- **dkjson** + 纯 Lua `cjson` 兼容垫片（满足 `require("cjson")`）
- **luasocket** 纯 Lua 桥接垫片（基于 nginx cosocket，满足 `require("socket")`）
- **qist/waf** 纯 Lua Web 应用防火墙（含 `rule-config` 规则集）

## 使用方法

### 自动构建
工作流会每天凌晨自动检查 nginx 官方仓库，如果发现新版本会自动构建并创建 Release。

### 手动触发
1. 进入 GitHub 仓库的 Actions 页面
2. 选择 `Auto Build Nginx Multi-Platform` 工作流
3. 点击 `Run workflow`

### 下载二进制包
1. 进入 GitHub 仓库的 Releases 页面
2. 选择对应版本
3. 下载适合您系统的二进制包

## 构建流程

```
┌─────────────────────────────────────────────────────────────┐
│  1. 检查 nginx 官方仓库的最新版本                           │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  2. 对比本地仓库是否已存在该版本的 tag                       │
└─────────────────────────────────────────────────────────────┘
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
┌─────────────────────┐    ┌──────────────────────────────┐
│ 已存在 → 跳过构建    │    │ 不存在 → 开始多平台构建        │
└─────────────────────┘    └──────────────────────────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    ▼                 ▼                 ▼
           ┌─────────────┐   ┌─────────────┐   ┌─────────────┐
           │  glibc      │   │  musl       │   │   macOS     │
           │  (Ubuntu/   │   │  (Alpine/   │   │  Windows    │
           │   Debian/   │   │   OpenWrt)  │   │             │
           │   RHEL/     │   │             │   │             │
           │   CentOS)   │   │             │   │             │
           └─────────────┘   └─────────────┘   └─────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────┐
│  3. 静态编译 + 打包, 创建 Release 并上传所有平台的二进制包   │
└─────────────────────────────────────────────────────────────┘
```

## 技术栈

- **nginx**: `1.31.3`（版本号由 `NGINX_VER` 环境变量贯穿控制，默认见各脚本）
- **OpenSSL**: 原生 `openssl-3.6.3`（启用 TLS 1.3 + nginx 原生 HTTP/3，无 QuicTLS 依赖）
- **LuaJIT**: openresty/luajit2 2.1（静态编入）
- **mimalloc**: microsoft/mimalloc 2.1.9（静态编入，`MI_OVERRIDE` 接管默认分配器）
- **依赖库**（静态链接，随包发布）:
  - pcre2 / zlib / xz (liblzma) / libxml2 / libxslt / brotli
- **构建工具**: GitHub Actions
- **容器**: Docker（CentOS 7 + devtoolset-9 提供 gcc 9，arm64 容器原生编译，非交叉编译）
- **架构**: amd64 (glibc), arm64 (glibc)；musl 用于 Alpine

> 注：所有第三方库与 Lua 生态均**静态编入**单一 nginx 二进制，运行时无外部动态依赖（可用 `ldd` 验证无 ssl/crypto/luajit/mimalloc 动态链接）。

## 注意事项

1. **Linux 兼容性**: 不同发行版的二进制包不兼容，请下载对应系统的包
2. **macOS**: 需要 macOS 10.15+
3. **Windows**: 需要 Windows 10+
4. **ARM 架构**: 在 ARM64 (aarch64) 硬件或 aarch64 容器中**原生编译**，无需交叉编译或 QEMU 模拟

## 许可证

MIT License

## 贡献

欢迎提交 Issue 和 Pull Request！