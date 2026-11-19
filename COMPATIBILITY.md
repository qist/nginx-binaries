# 产物 glibc 兼容性说明

> 本仓库所有 **glibc 系**产物均在 **CentOS 7.9（glibc 2.17）** 上构建，
> 二进制符号版本上限为 `GLIBC_2.17`。**Alpine/musl** 产物单独构建，见文末。

## 一、结论（先看这个）

| 产物 | 兼容范围 | 备注 |
|---|---|---|
| `*_glibc_amd64.tar.gz`（含默认/apps/fhs 变体） | 所有 **glibc ≥ 2.17** 的 x86_64 发行版 | 向后兼容，越新越好跑 |
| `*_musl_amd64.tar.gz` | Alpine / 其它 musl 系统 | 基础镜像需 `apk add libgcc` |

**glibc 向后兼容**：老系统编译的二进制在新系统上一定能跑（老符号永远保留）。
反过来不成立——在新系统（如 Ubuntu 24）上编译的产物会引用 `GLIBC_2.34+` 符号，
拿到 CentOS 7 上会直接报 `version 'GLIBC_2.34' not found`。
这就是本仓库坚持用 **CentOS 7 作为构建底座**的原因：它是我们支持目标里最老的。

## 二、二进制动态依赖清单（ldd 实测）

除 OpenSSL / PCRE2 / zlib / libxml2 / libxslt / brotli / LuaJIT / mimalloc 全部静态编入外，
仅剩以下动态依赖：

```
libm.so.6        (glibc)
libdl.so.2       (glibc; 2.34+ 已并入 libc, 保留兼容符号)
libpthread.so.0  (glibc; 同上)
libcrypt.so.1    (glibc 的 libcrypt; RHEL 9+/Fedora 需兼容包, 见下表)
libgcc_s.so.1    (gcc 运行库)
libc.so.6        (glibc)
ld-linux-x86-64.so.2 (动态链接器)
```

## 三、分发行版兼容表

| 发行版 | glibc | 兼容性 | 需要的操作 |
|---|---|---|---|
| CentOS 7.9 | 2.17 | ✅ 开箱即用 | 无（构建底座） |
| RHEL / Rocky / Alma / CentOS Stream **8** | 2.28 | ✅ 开箱即用 | 无 |
| RHEL / Rocky / Alma / CentOS Stream **9** | 2.34 | ⚠️ 缺 libcrypt.so.1 | `dnf install libxcrypt-compat` |
| **RHEL / Rocky / Alma / CentOS Stream 10** | 2.39 | ⚠️ 缺 libcrypt.so.1 | `dnf install libxcrypt-compat` |
| Fedora 34+ | 2.33+ | ⚠️ 缺 libcrypt.so.1 | `dnf install libxcrypt-compat` |
| Ubuntu 16.04 – 24/26 | 2.23 – 2.42 | ✅ 开箱即用 | 无（libcrypt1 默认已装） |
| Debian 8+ | 2.19 – 2.41 | ✅ 开箱即用 | 无 |
| Amazon Linux 2 / 2023 | 2.26 / 2.34 | ✅ 开箱即用 | 无 |
| openSUSE / SLES 12+ | 2.22+ | ✅ 开箱即用 | 无 |
| Arch Linux | 最新 | ✅ 开箱即用 | 无 |
| Alpine | musl | ❌ 别用 glibc 包 | 改用本仓库 `musl_amd64` 产物 |

**RHEL 9 起的变化**（也就是"库名字改了"的实情）：
- glibc 自带的 libcrypt 已被 `libxcrypt` 取代，默认只提供新的 `libcrypt.so.2`
- 旧 ABI 的 `libcrypt.so.1` 被移入 **`libxcrypt-compat`** 包，且**不再默认安装**
- nginx 链接的是 `libcrypt.so.1`（auth_basic 等使用），所以在 RHEL 9/10、
  Rocky/Alma/Stream 9/10、Fedora 34+ 上**必须装兼容包**：

```bash
dnf install -y libxcrypt-compat
```

- 另：RHEL 10 起默认不再安装 32 位 (i686) multilib，对 x86_64 产物无影响。
- **RHEL 10 硬件门槛**：RHEL 10 全家（Rocky/Alma/Stream 10）的 glibc 自身要求 CPU
  支持 **x86-64-v3**（AVX2/BMI2，约 2013 年 Haswell 及之后）。在不支持 v3 的老 CPU 上
  连系统本身都无法运行（`Fatal glibc error: CPU does not support x86-64-v3`），
  这与我们的产物无关——本仓库二进制是 x86-64 基线版，CPU 只要比目标系统新即可。
  （实测：2026-11-19 在不支持 v3 的老 Xeon 上，Rocky 10 容器 glibc 直接 Fatal error。）

## 四、常见报错对照

| 报错 | 原因 | 解决 |
|---|---|---|
| `libcrypt.so.1: cannot open shared object file` | RHEL 9+/Fedora 缺兼容包 | `dnf install libxcrypt-compat` |
| `version 'GLIBC_2.xx' not found` | 二进制构建底座 glibc 比目标系统新 | 换用本仓库 CentOS 7 构建的产物（正常不会遇到） |
| `No such file or directory` 但文件存在 | musl 包跑在 glibc 系统上（或反之） | 换对应 libc 系的产物 |
| `libgcc_s.so.1: cannot open shared object file` | 极简系统（如 Alpine 基础镜像）缺 gcc 运行库 | glibc 系: `yum/dnf/apt install libgcc`；Alpine: `apk add libgcc` |

## 五、如何验证一个二进制能在目标系统跑

```bash
# 1) 查符号版本上限（产物最高 GLIBC_2.17 即全兼容）
objdump -T nginx | grep -oE "GLIBC_[0-9.]+" | sort -uV | tail -3

# 2) 查动态依赖是否满足
ldd nginx            # 目标机上跑, 不得有 "not found"

# 3) 干净容器实测（不污染宿主）
docker run --rm -v $PWD:/t -w /t rockylinux:9 bash -c "dnf -y install libxcrypt-compat >/dev/null && ./nginx -V"
docker run --rm -v $PWD:/t -w /t centos:7 bash -c "./nginx -V"
```

## 六、musl（Alpine）产物说明

- 仅动态依赖 musl libc 与 `libgcc_s.so.1`
- Alpine **基础镜像不含 libgcc**，部署前需：`apk add libgcc`
- 其余依赖（OpenSSL 等）同样全部静态编入

## 七、维护注意

1. **构建底座永远用 CentOS 7.9**（`scripts/centos7-docker-test.sh` / CI 的
   `centos:7.9.2009` job）。换更高版本底座会抬高 GLIBC 符号上限，破坏老系统兼容。
2. 引入新依赖库时同样要静态链入（参考 `build-nginx.sh` 的 LD_OPT 做法），
   不得引入新的 `.so` 动态依赖。
3. 每次发版跑一遍第五节的验证命令（CI 里已有 ldd 检查：`✅ 全部静态编入`）。
