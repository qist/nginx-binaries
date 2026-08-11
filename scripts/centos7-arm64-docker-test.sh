#!/usr/bin/env bash
# 本地测试用:在 centos:7.9.2009 容器内,用官方 vault 源 + 代理拉取依赖,跑通完整静态构建。
# 仅用于 192.168.2.186 上的 docker 实测,不进入正式 CI。
set -e

# 代理: 不在脚本写死。如需访问外网官方源/源码包, 自行在容器里 export 代理环境变量,
# 例如: export https_proxy=http://<host>:<port> http_proxy=http://<host>:<port>
# 注意: github.com 始终直连(脚本内已清空 git 代理), 不要为 github 设代理。

# 1) 替换 yum 源为官方 altarch vault 归档 (arm64/aarch64;EOL 后官方归档,外网可访问,全走代理)
cat > /etc/yum.repos.d/CentOS-Base.repo <<'EOF'
[base]
name=CentOS-7.9.2009 - Base
baseurl=https://vault.centos.org/altarch/7.9.2009/os/$basearch/
gpgcheck=0
enabled=1
[updates]
name=CentOS-7.9.2009 - Updates
baseurl=https://vault.centos.org/altarch/7.9.2009/updates/$basearch/
gpgcheck=0
enabled=1
[extras]
name=CentOS-7.9.2009 - Extras
baseurl=https://vault.centos.org/altarch/7.9.2009/extras/$basearch/
gpgcheck=0
enabled=1
[sclo]
name=CentOS-7.9.2009 - SCLo
baseurl=https://vault.centos.org/altarch/7.9.2009/sclo/$basearch/sclo/
gpgcheck=0
enabled=1
[sclo-rh]
name=CentOS-7.9.2009 - SCLo-rh
baseurl=https://vault.centos.org/altarch/7.9.2009/sclo/$basearch/rh/
gpgcheck=0
enabled=1
EOF
rm -f /etc/yum.repos.d/CentOS-SCLo*.repo /etc/yum.repos.d/CentOS-Extras.repo /etc/yum.repos.d/CentOS-*.repo.rpmsave 2>/dev/null || true

yum clean all
yum makecache

# 2) 基础工具 + 编译依赖
yum install -y git curl wget tar pkgconfig autoconf automake libtool \
  make perl perl-Time-Piece perl-IPC-Cmd patch file
# devtoolset-9 提供 gcc 9(老 gcc 4.8.5 编不了 mimalloc 2.1.9)
yum install -y devtoolset-9-gcc devtoolset-9-gcc-c++

# 3) cmake 3.27(Kitware 预编译 aarch64;xz 要求 >=3.20)
curl -sL -o /tmp/cmake.tar.gz \
  https://github.com/Kitware/CMake/releases/download/v3.27.9/cmake-3.27.9-linux-aarch64.tar.gz
tar xzf /tmp/cmake.tar.gz -C /tmp
ln -sf /tmp/cmake-3.27.9-linux-aarch64/bin/cmake /usr/local/bin/cmake
cmake --version | head -1

# 4) 进入工作区,清理裸机残留,启用新 gcc,跑完整构建链
cd /workspace
source /opt/rh/devtoolset-9/enable
export CC=gcc CXX=g++
export MODULE_ROOT=/workspace LIBS_PREFIX=/workspace/libs WORK=/workspace/work
NGINX_VER="${NGINX_VER:-1.31.3}"
OPENSSL_VER="${OPENSSL_VER:-3.6.3}"
export NGINX_VER OPENSSL_VER

# 清理宿主挂载目录里残留的裸机构建产物(含写死旧绝对路径的 Makefile/configdata)
# 避免 docker 内复用导致 cmake/nginx configure 路径冲突。幂等,首次运行无害。
echo "==> 清理可能污染构建的残留产物"
rm -rf "$MODULE_ROOT/openssl-$OPENSSL_VER" "$WORK" \
       "$MODULE_ROOT/nginx-$NGINX_VER" 2>/dev/null || true
for m in "$MODULE_ROOT"/{ngx_devel_kit,set-misc-nginx-module,ngx_http_substitutions_filter_module,nginx-http-auth-digest,ngx_cache_purge,nginx-upsync-module,echo-nginx-module,mod_zip,nginx-upstream-dynamic-servers,headers-more-nginx-module,nginx-module-vts,nginx-dav-ext-module,ngx_brotli,ngx-fancyindex,nginx-module-sts,nginx-module-stream-sts,lua-nginx-module,stream-lua-nginx-module,lua-upstream-nginx-module}; do
  [ -d "$m" ] && rm -rf "$m/objs" "$m/Makefile" 2>/dev/null || true
done

bash scripts/ci-build.sh /workspace "$NGINX_VER" glibc_arm64 tar.gz
