## 构建时遇到 undefined reference to 的问题

是因为 base 里面安装了 a 包，但是没有安装 a 的 dev 包，在使用 deb-source 安装 deb 依赖时，会跳过 a 包，只安装 a 的 dev 包。
但是 a-dev 包里面的 so 文件一般都是软链接，使用相对路经指向同目录的 a 包里面的 so 文件。

但因为 a 包是在 base 安装的，so 文件在系统目录，a-dev 包是通过 deb-source 安装的，so 文件放在/runtime 下面。

解决办法是 从 base 中删除 a 包或在 base 中安装 a 的 dev 包。

有一个 undefined reference to `dlopen' 比较特殊，libdl qt 会进行两次测试，第一次不加 -libdl 会报错，第二次会加测试正常通过。

## 构建时遇到 include_next 的问题

include_next 的意义是在当前 path 的下一个 path 中查找头文件，所以要先确定当前的 path 列表和报错的文件所在的 path。
解决办法是调整 CPLUS_INCLUDE_PATH，保证要查找的头文件的 path 位于报错的头文件的 path 的后面。

## 构建耗时优化

一次 `ll-builder build` 的耗时分布大致是：下载源码（含 webkit2gtk 源码克隆）→ 安装 build_depends →
从源码编译 webkit2gtk（大头）→ 打包 → `build.bash` 组装 runtime → 提交 layer。
本次改动主要集中在"少编译、少下载、打包少干活"三件事上。

### 1. 只编译 webkit2gtk-4.1（soup3/GTK3）一个变体（最大收益）

上游 `debian/rules` 默认编译三个变体，每个变体都是一次完整的 WebKit 编译：

| 变体 | 产物 | 本 runtime 是否需要 |
| --- | --- | --- |
| soup2 | libwebkit2gtk-4.0-37 / libjavascriptcoregtk-4.0-18（GTK3 + libsoup2） | 否 |
| soup3 | libwebkit2gtk-4.1-0 / libjavascriptcoregtk-4.1-0（GTK3 + libsoup3） | **是** |
| gtk4 | libwebkitgtk-6.0-4 / libjavascriptcoregtk-6.0-1（GTK4 + libsoup3） | 否 |

新增补丁 `0002-build-only-webkit2gtk-4.1-soup3-flavour.patch`，把 `ENABLE_SOUP2`、`ENABLE_GTK4`
改为 `NO`（`ENABLE_SOUP3=YES` 不变），于是 `debian/rules` 里 soup2/gtk4 的
`dh_auto_configure/build/install` 全部退化为 `:`，只剩 `build-soup3` 真正执行。

注意一个坑：`debian/control` 是由 `debian/rules` 根据上面的开关生成的，但 rules 里的
`debian/control:` 规则只被 `override_dh_auto_clean` 依赖，`build`/`binary` 走的是没有先决条件的
`%:` 模式规则；而 `dpkg-buildpackage -nc` 会跳过 clean。结果 dh 启动时读到的仍是仓库里提交的
21 个包的 control，会去打包根本没编译的 soup2/gtk4 包，在 `dh_install` 阶段报
`dh_install: error: missing files, aborting`。

所以补丁里加了一条只声明依赖、不带命令的规则，让 dh 启动前先重新生成 control：

```make
build binary clean: debian/control
```

重新生成后 control 只有 9 个包（4.1 的 6 个 + bookworm 兼容的 `libjavascriptcoregtk-4.0-bin`、
`libwebkit2gtk-4.0-doc`、`webkit2gtk-driver`），rules 里再用
`-Nlibjavascriptcoregtk-4.0-bin -Nlibwebkit2gtk-4.0-doc` 排除两个，实际构建 7 个包。

### 2. 打包阶段跳过 dbgsym / 文档

```sh
# 每个并行任务按 4 GB 内存估算，再受 nproc 限制（16 核 / 30 GB → 7）
mem_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1048576 ))
jobs=$(( mem_gb / 4 ))
if [ "$jobs" -gt "$(nproc)" ]; then jobs=$(nproc); fi
if [ "$jobs" -lt 2 ]; then jobs=2; fi
export DEB_BUILD_OPTIONS="parallel=$jobs nocheck nodoc noautodbgsym terse"
```

- `noautodbgsym`：不再生成 6 个 `-dbgsym` 包。按 Debian 官方 2.5x 版本的数据，
  `libwebkit2gtk-4.1-0-dbgsym` 约 111 MB、`libjavascriptcoregtk-4.1-0-dbgsym` 约 33 MB，
  三个变体合计约 430 MB 的 strip/压缩/写盘全部省掉；
- `nodoc` 加上 gtk4 变体关闭：文档只在 gtk4 变体里生成（soup2/soup3 的 configure 行尾本来就固定
  `-DENABLE_DOCUMENTATION=OFF`），关掉 gtk4 后文档彻底不编译，`nodoc` 只是双保险；
- `parallel`：按内存估算并行度，而不是直接 `$(nproc)`。webkit2gtk 默认开 unified build，
  单个编译单元的内存峰值能到几 GB，在 16 核 / 30 GB 的机器上 `-j16` 会把内存直接吃光、
  整机卡进 swap（实测过一次整机假死）。build 脚本里按"每个并行任务 4 GB"估算
  （16 核 / 30 GB → 7 个任务），再受 nproc 限制，兼顾速度和可用性；
- `nocheck`/`terse`：`override_dh_auto_test:` 本来就是空的，`nocheck` 只是保险；`terse` 只精简日志。

### 3. runtime 包清单改用 buildext 安装 + 拷贝（去掉 244 个 file 源和 install_dep）

原来的做法是：yaml 里写 244 条 `kind: file` 的 deb 源 → ll-builder 下载到 `/project/linglong/sources`
→ `install_dep` 逐个解开再筛选拷贝。问题有两个：

- 这 244 条源和 `build_depends` 大量重复：webkit 的编译依赖（`libgtk-4-dev`、`libsoup-3.0-dev`……）
  本来就要装进构建容器，再下载一份相同的 deb 纯属浪费（多下载 153 MB、多解包 200 多个 deb）；
- `install_dep` 用容器的 `/var/lib/dpkg/status` 当排除表，会把构建依赖装进容器的包全部跳过，
  导致 runtime 缺 `libgtk-4-1`、`libsoup-3.0-0` 等运行必需库（详见下文"已修复的问题"）。

现在改成：

1. `runtime-packages.list` 记录 runtime 需要哪些包（`@` 开头的是本仓库编译产出的包）；
2. 这些包直接写进 yaml 的 `buildext.apt.build_depends`，由 ll-builder 在构建容器里 `apt install`，
   它们同时也是编译 webkit 需要的依赖，一次安装两用；
3. `build.bash` 在 build 阶段末尾把这些包的文件（`dpkg -L`）从容器拷进 `/runtime`：
   - 依赖闭包用 `apt-cache depends --recurse --no-recommends` 现算，再减掉 base 的 `/packages.list`；
   - 自己编译的 7 个包直接从 `/project/linglong/sources/*.deb` 里取文件（`dpkg -x` 解到临时目录），
     不需要 `dpkg -i`，也就不会被仓库里那套 2.48/2.50 的依赖关系卡住；
   - 拷完统一做 `.pc` 前缀替换、绝对软链接改写、RUNPATH 改写、`ldconfig -C`，最后断言关键库存在。

效果：yaml 从 869 行降到 153 行，不再下载 deb，runtime 内容反而更完整——235 个包 / 8462 个文件 /
451 MB，`libwebkit2gtk-4.1.so.0` 的动态依赖只差 libcaca 的可选 GL 插件 `libglut.so.3.12`
（base 和源里都没有 freeglut，旧 runtime 也一样）。

### 3.1 build_depends 精简（77 → 66）

判断依据是上游 `debian/control.in` 的 `Build-Depends`，再按本次"只编译 soup3/GTK3 一个变体"的
实际配置删掉用不到的项。保留的 66 条 = 打包工具 + 上游声明的依赖 + runtime 根包。

删掉的 10 条及依据：

| 条目 | 为什么不需要 |
| --- | --- |
| `libsoup2.4-dev` | configure 行里 `-DUSE_SOUP2=OFF`，soup2 变体的构建命令是 `@:` |
| `libjxl-dev` | configure 行里 `-DUSE_JPEGXL=OFF` |
| `libsysprof-capture-4-dev` | configure 行里 `-DUSE_SYSPROF_CAPTURE=OFF` |
| `gi-docgen` | `ENABLE_DOCUMENTATION=OFF`，文档只在 gtk4 变体里生成，且 doc 包被 `-N` 排除 |
| `jdupes` | 只在 `debian/rules` 的文档合并步骤里用，文档包不产出了 |
| `devscripts` | 构建只用 `dpkg-buildpackage`（来自 `dpkg-dev`），没调用 `debuild`/`dch` |
| `equivs` | 构建不生成占位包；它原本只是顺带把 `debhelper` 拉进容器 |
| `git` | 源码由 ll-builder 自己拉取，构建脚本不跑 git |
| `clang`（无版本） | `debian/rules` 里固定用 `clang-16`/`clang++-16`，已单独列出 |
| `lld-16` | `debian/rules` 没有 `-fuse-ld=lld`，上游 `Build-Depends` 也没有 lld |

因为 `devscripts`/`equivs` 会顺带装上 `debhelper`、`dpkg-dev`（`dpkg-checkbuilddeps` 要检查
`debhelper-compat (= 13)`），精简后把这两个显式写进列表。

保留但值得说明的两条：

- `libgirepository1.0-dev`：`g-ir-scanner` 需要 `gobject-introspection-1.0.pc`，GIR/typelib 是这个
  runtime 的必需产物，显式列出比依赖 `gobject-introspection` 的隐式依赖稳；
- `libgstreamer-plugins-bad1.0-dev`：编译其实不需要（上游 `Build-Depends` 里没有），但它的
  运行时库会被拷进 `/runtime`，和旧 runtime 的媒体能力对齐，删了会少一批解码器。

补充一个顺手发现的问题：`build.bash`/旧 `install_dep` 里都会用 `patchelf` 改写 RUNPATH，
但容器里其实没装 `patchelf`（v5 的日志里一条 `FIX RUNPATH` 都没有，所以一直没暴露）。扫过 v5 的
runtime 层和 base 层：runtime 里没有任何库的 RUNPATH 指向 `/usr`（只有 base 自己的 pulseaudio
模块有），所以这一步目前是空转。`build.bash` 里改成"有 patchelf 才改写，没有就打印警告"，
既不新增依赖，也不会再出现"跑完 3 小时最后一步 command not found"的意外。

### 3.2 ccache 其实一直没生效（0 命中）

用容器里自带的 ccache 直接读缓存统计（第二轮构建结束时）：

```
Cacheable calls:    3193 / 3193 (100.0%)
  Hits:                0 / 3193 ( 0.00%)
  Misses:           3193 / 3193 (100.0%)
Local storage:  Cache size (GiB): 0.4 / 5.0
```

原因：`debian/rules` 里 `export CCACHE_DIR=$(CURDIR)/ccache` 把缓存放在源码树里，而
ll-builder 每次构建都会从自己的 fetch cache（`linglong/cache`，439 MB）重新展开源码树，
缓存目录跟着被删掉。所以第二轮那 2h56m 是**一次完整的冷编译**（3193 个 `.o` 全部重编），
和上一轮 3h06m 的差别只是机器负载，不是 ccache 命中。

修法：

- 新增补丁 `0003-ccache-dir-outside-build-tree.patch`，把那一行改成
  `export CCACHE_DIR ?= $(CURDIR)/ccache`（make 的 `?=` 会被环境变量覆盖）；
- build 段里 `export CCACHE_DIR=/project/linglong/ccache`：容器里的 `/project` 就是宿主
  仓库目录（bind mount，构建产物 `build-soup3` 2.1 GB 都能在宿主看到），而 `linglong/`
  在源码树（`linglong/sources/webkit2gtk`）之外，ll-builder 每次重新展开源码树不会碰它；
- `ccache --max-size=5G`，编译前后各打一行 `ccache -s`，CI 日志里能直接看命中率。

为什么不放在叠加层里（`/var/cache/ccache`）：那样只有在容器的 overlay upperdir 被复用时
才有效，base 一升级或者 `ll-builder` 重建 overlay 缓存就没了；放 `/project/linglong/ccache`
是宿主上的真实目录，跟着仓库走，`ls`/`du`/删掉都直观。

修完之后的实测（同一台机器、同一份源码）：

| 构建 | ccache 状态 | 编译 + 打包 | 整个 `ll-builder build` |
| --- | --- | --- | --- |
| v6（缓存写在源码树里） | 0 命中 / 3193 | 2h56m04s | ≈2h59m30s |
| v7（缓存改到源码树外，首次填充） | 3193 miss（缓存空） | 2h41m06s | ≈2h45m |
| v8（复用 v7 的缓存，`/var/cache/ccache`） | 3193/3193 全命中 | 9m39s | ≈12m |
| v9（缓存放 `/project/linglong/ccache`） | 3193/3193 全命中（3183 direct + 10 preprocessed） | **9m35s** | **≈12m** |

也就是说命中率拉满之后，编译阶段从 2 小时 40 分掉到 10 分钟以内（剩下的时间是 5 个大二进制的链接，
ccache 不管链接）。缓存约 430 MB，`max_size=5G` 完全够。

注意：只有本机重复构建（或 CI 把 `linglong/` 或 `/project/linglong/ccache` 挂成缓存卷）才有收益；
CI 每次都是干净容器的话，ccache 依然等于没有。

### 4. 修正 deb 产物检查（原来写死 2.48.0，且是自我拷贝）

`dpkg-buildpackage` 默认把 deb 输出到源码目录的父目录，也就是 `/project/linglong/sources`——
正好是 `install_dep` 的扫描目录。旧 build 脚本最后那两行
`cp -a ../*_2.48.0-1deepin1_amd64.deb /project/linglong/sources/` 不仅是自己拷自己（空操作），
写死的版本号还和 2.50.4 对不上，glob 匹配不到时只打印一行错误就继续，属于静默失败。
现在改成按实际包名检查产物，缺文件直接让构建失败：

```sh
ls -1 ../libwebkit2gtk-4.1-0_*.deb ../libwebkit2gtk-4.1-dev_*.deb \
      ../libjavascriptcoregtk-4.1-0_*.deb ../libjavascriptcoregtk-4.1-dev_*.deb \
      ../gir1.2-webkit2-4.1_*.deb ../gir1.2-javascriptcoregtk-4.1_*.deb >/dev/null
```

### 5. 阶段计时

build 脚本在 webkit2gtk 编译前后、`build.bash` 组装 runtime 前后都会打印时间戳
（`[build] ... $(date)`），CI 上可以直接 grep 出各阶段耗时；`build.bash` 里还打印了
包数量和拷贝的文件数。

### 实测（16 核 / 30 GB，base 25.2.2.8）

| 阶段 | 耗时 |
| --- | --- |
| 源码获取 + 安装 build_depends（webkit2gtk 516 MB 克隆、244 个 deb、739 个包） | 7m35s |
| webkit2gtk 编译（单变体，8497 个 ninja 目标，`-j7`） | ≈3h02m |
| 打包（`dh_strip` + 7 个 deb 的 `dpkg-deb`，xz） | ≈4m30s |
| `build.bash` 组装 runtime（235 个包，8462 个文件） | ≈48s |
| 提交 layer（develop + binary） | 6s |
| **合计** | **3h14m08s** |

> 上表是 7 并行的实测值。同一台机器上 `-j16` 会因 WebKit unified build 的单 TU 内存峰值把
> 30 GB 内存和 zram 全部吃满（实测内存耗尽后整机卡死），所以 yaml 里按"每 4 GB 内存 1 个任务"
> 估算并行度；7 个任务时 cgroup 内存峰值 18.2 GB，机器全程可用。

### 第二轮实测（去掉 file 源 + buildext 组装，base 25.2.2.8，同一台机器）

| 阶段 | 第一轮（244 个 file 源 + install_dep） | 第二轮（buildext + `build.bash`） |
| --- | --- | --- |
| 依赖准备（下载/安装 build_depends、拉源码） | 7m35s | ≈10s（fetch cache 与 overlay 复用；冷启动约 5-6 min） |
| webkit2gtk 编译 + 打包 | 3h06m14s | 2h56m04s（ccache 命中） |
| 组装 runtime | 13s（251 个 deb 里实际只装 45 个包） | 1m00s（235 个包、8462 个文件） |
| 提交 layer | 6s | ≈5s |
| **合计** | **3h14m08s** | **≈2h59m30s** |

时间上省的不多（主要是少下载 153 MB deb、少解包 200 多个包，组装反而多花 40 秒），
真正的收益是 **runtime 内容正确**：第一轮因为 `install_dep` 拿容器的 dpkg status 当排除表，
235 个包里 206 个被跳过，`libwebkit2gtk-4.1.so.0` 缺 28 个 soname 根本加载不了；第二轮只剩
libcaca 的可选 GL 插件 `libglut.so.3.12` 一个缺失（base 和源里都没有 freeglut，旧 runtime 同样没有）。

### 优化前后对比

| 项目 | 优化前 | 优化后 |
| --- | --- | --- |
| webkit2gtk 编译变体数 | 3（soup2/soup3/gtk4） | 1（soup3） |
| ninja 编译目标数 | ≈3 × 8497 | 8497 |
| file 源数量 / 下载量 | 565 个 / 314.89 MB | 0 个 / 0 MB（改用 buildext 安装） |
| dbgsym 产物 | 6 个，约 430 MB | 不生成 |
| 文档 | gtk4 变体里用 gi-docgen 生成 | 不生成 |
| 编译阶段耗时 | ≈3 × 单变体（同机同并行度约 9h06m，加文档/dbgsym 约 9h20m） | 3h02m |
| 整次构建 | ≈9h40m（推算） | 3h14m（实测） |

并行度受内存限制时，省掉的不是"一倍时间"，而是三分之二的编译工作：单变体 8497 个 ninja
目标里，WebCore 的 unified TU 占了大部分时间，删掉两个变体等于把这段最重的编译从 3 遍减到 1 遍。

### 实测产物核对（本次构建）

- 7 个 deb（`libwebkit2gtk-4.1-0/-dev`、`libjavascriptcoregtk-4.1-0/-dev`、
  `gir1.2-webkit2-4.1`、`gir1.2-javascriptcoregtk-4.1`、`webkit2gtk-driver`）版本 2.50.4，无 4.0/6.0 产物；
- runtime layer 451 MB（235 个包）：`lib/x86_64-linux-gnu/libwebkit2gtk-4.1.so.0.19.7`（92.8 MB）、
  `libjavascriptcoregtk-4.1.so.0.9.9`（32.5 MB）、3 个 4.1 typelib、webkit 的 5 个进程二进制，
  以及 gtk4/libsoup3/gstreamer 插件等运行依赖；`.pc` 里的 `prefix` 是 `/runtime`。

> 上面这组数字是"只装了 build_depends 的容器 + 现成 deb"干跑 `build.bash` 得到的（跳过编译），
> 真实构建的 runtime 内容与之等价。

### 已修复的问题（PR#5 引入的 runtime 缺库）

`install_dep` 会用构建容器里的 `/var/lib/dpkg/status` 当排除表，于是**构建依赖装进容器的包
不会再进 runtime**。PR#5 把 `libgtk-4-dev` / `libgtk-3-dev` / `libsoup-3.0-dev` 等加进
`build_depends` 之后，源里 244 个 deb 有 206 个被跳过，其中包含 `libgtk-4-1`、
`libsoup-3.0-0`、`libgraphene-1.0-0`、`libmanette-0.2-0` 等运行必需库，
`libwebkit2gtk-4.1.so.0` 的依赖因此不闭合（只剩 45 个包、292 MB 的 layer 就是这么来的）。

新的 `build.bash` 按"base 的 `packages.list` + apt 依赖闭包"决定拷哪些包，不再看容器的
dpkg status，这个问题从设计上消失；另外补了一步断言，关键库没进 runtime 就直接让构建失败。

### 需要 4.0（soup2）或 6.0（gtk4）包时

把 0002 补丁里的 `ENABLE_SOUP2` / `ENABLE_GTK4` 改回 `YES`，并把对应包加进
`build_depends`（或改为从源码产出，在 `runtime-packages.list` 里用 `@` 标出）即可，
其它优化项不受影响。

### 维护 runtime 包清单（base 升级后）

`runtime-packages.list` 里列的是"runtime 需要哪些包"（`@` 开头的是本仓库编译产出），
它们同时要出现在 yaml 的 `build_depends` 里（`@` 的那些除外）。base 升级后不用改清单：
`build.bash` 每次都会用 base 的 `/packages.list` 重新算差集，base 里已经有的包自动跳过。

要核对某个包为什么进/没进 runtime，可以在构建容器里手工跑：

```sh
# 依赖闭包（再减去 base 已有的包）
apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
    --no-breaks --no-replaces --no-enhances libgtk-4-1 ... | awk '/^[A-Za-z0-9]/ {print $1}' | sort -u
awk '$1=="Package:"{print $2}' /packages.list | sort -u
```

离线复跑（不编译 webkit2gtk）：

```sh
PREFIX=/tmp/rt BASE_LIST=/var/lib/linglong/layers/*/files/packages.list \
    RUNTIME_PKGS="libgtk-4-1 libsoup-3.0-0 ..." bash ./build.bash
```

