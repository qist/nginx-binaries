# nginx-binaries

自动构建多平台 nginx 二进制包的 GitHub Actions 工作流。

## 功能特性

- ✅ **自动检测新版本** - 每天自动检查 nginx 官方仓库的最新版本
- ✅ **增量构建** - 只对新发布的版本进行构建，避免重复工作
- ✅ **多平台支持** - 覆盖主流操作系统和架构
- ✅ **丰富的模块** - 包含常用的第三方 nginx 模块
- ✅ **HTTP/3 支持** - 使用 QuicTLS 编译，原生支持 QUIC/HTTP3

## 支持的平台

| 操作系统 | 架构 | 包名格式 |
|----------|------|----------|
| Ubuntu | amd64 | `nginx_{version}_ubuntu_amd64.tar.gz` |
| Ubuntu | arm64 | `nginx_{version}_ubuntu_arm64.tar.gz` |
| Debian | amd64 | `nginx_{version}_debian_amd64.tar.gz` |
| Debian | arm64 | `nginx_{version}_debian_arm64.tar.gz` |
| Red Hat | amd64 | `nginx_{version}_redhat_amd64.tar.gz` |
| Red Hat | arm64 | `nginx_{version}_redhat_arm64.tar.gz` |
| Alpine | amd64 | `nginx_{version}_alpine_amd64.tar.gz` |
| Alpine | arm64 | `nginx_{version}_alpine_arm64.tar.gz` |
| macOS | amd64 | `nginx_{version}_macos_amd64.tar.gz` |
| macOS | arm64 | `nginx_{version}_macos_arm64.tar.gz` |
| Windows | amd64 | `nginx_{version}_windows_amd64.zip` |

## 编译的模块

### 核心模块
- `--with-compat` - 兼容模式
- `--with-pcre-jit` - PCRE JIT 支持
- `--with-http_ssl_module` - SSL 支持
- `--with-http_v3_module` - HTTP/3 支持
- `--with-http_stub_status_module` - 状态页
- `--with-http_realip_module` - 真实 IP
- `--with-http_gzip_static_module` - gzip 静态压缩
- `--with-http_sub_module` - 字符串替换
- `--with-http_addition_module` - 内容添加
- `--with-http_dav_module` - WebDAV
- `--with-http_flv_module` - FLV 支持
- `--with-http_mp4_module` - MP4 支持
- `--with-http_gunzip_module` - gunzip 支持
- `--with-http_random_index_module` - 随机索引
- `--with-http_secure_link_module` - 安全链接
- `--with-http_degradation_module` - 降级支持
- `--with-http_slice_module` - 切片支持
- `--with-threads` - 线程支持
- `--with-stream` - 流模块
- `--with-stream_ssl_module` - 流 SSL
- `--with-stream_realip_module` - 流真实 IP

### 第三方模块
- `set-misc-nginx-module` - 变量处理
- `ngx_http_substitutions_filter_module` - 内容过滤替换
- `nginx-http-auth-digest` - Digest 认证
- `nginx_upstream_check_module` - 上游健康检查
- `ngx_cache_purge` - 缓存清除
- `nginx-upsync-module` - 动态上游配置
- `echo-nginx-module` - 响应输出
- `mod_zip` - ZIP 压缩
- `nginx-upstream-dynamic-servers` - 动态服务器
- `headers-more-nginx-module` - 自定义响应头
- `nginx-module-vts` - 虚拟主机状态
- `nginx-dav-ext-module` - WebDAV 扩展
- `ngx_brotli` - Brotli 压缩
- `ngx-fancyindex` - 美观的目录索引

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
           │  Ubuntu     │   │  Red Hat    │   │   macOS     │
           │  Debian     │   │  Alpine     │   │  Windows    │
           │  FreeBSD    │   │             │   │             │
           └─────────────┘   └─────────────┘   └─────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────┐
│  3. 创建 Release 并上传所有平台的二进制包                    │
└─────────────────────────────────────────────────────────────┘
```

## 技术栈

- **OpenSSL**: QuicTLS `openssl-3.3.0` (支持 QUIC/HTTP3)
- **构建工具**: GitHub Actions
- **容器**: Docker (用于跨平台编译)
- **架构**: amd64, arm64

## 注意事项

1. **Linux 兼容性**: 不同发行版的二进制包不兼容，请下载对应系统的包
2. **macOS**: 需要 macOS 10.15+
3. **Windows**: 需要 Windows 10+
4. **ARM 架构**: 需要支持 ARM 的硬件或使用 QEMU 模拟

## 许可证

MIT License

## 贡献

欢迎提交 Issue 和 Pull Request！
