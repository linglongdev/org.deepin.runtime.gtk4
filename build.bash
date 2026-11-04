#!/bin/bash
# 把构建容器里已经装好的包装进 runtime 目录（$PREFIX = /runtime）。
#
# 包有两类：
#   1) buildext.apt 装进构建容器 /usr 的包（见 runtime-packages.list）
#   2) 本仓库编译出来的 webkit2gtk deb（@ 开头，文件直接从 deb 里取）
# base 里已经有的包会被跳过，只把差集拷进 runtime，替代原来的
# "kind: file 源 + install_dep 解 deb" 那套流程。
set -e

: "${PREFIX:?PREFIX 未设置（需要在 ll-builder 的构建环境里运行）}"

src_root=${SRC_ROOT:-/}                       # 文件来源根（离线自测时指向解包出来的假根）
base_list=${BASE_LIST:-/packages.list}        # base 的包清单
deb_dir=${DEB_DIR:-linglong/sources}          # 本仓库编译出来的 deb
pkg_list_file=${1:-runtime-packages.list}

base_pkgs=$(awk '$1=="Package:" {print $2}' "$base_list" 2>/dev/null | sort -u)

apt_roots=$(grep -vE '^[[:space:]]*(#|@|$)' "$pkg_list_file" | tr '\n' ' ')
built_pkgs=$(sed -n 's/^@//p' "$pkg_list_file" | grep -vE '^[[:space:]]*$' | tr '\n' ' ')

if [ -n "${RUNTIME_PKGS:-}" ]; then
    # 离线自测/CI 覆盖用：直接给包名列表
    pkgs=$(printf '%s\n' $RUNTIME_PKGS $built_pkgs | sort -u)
else
    # 自己编译的包的运行时依赖也要算进闭包（它们不在源仓库的包列表里）
    built_deps=$(for deb in "$deb_dir"/*.deb; do
                     [ -e "$deb" ] || continue
                     dpkg-deb -f "$deb" Depends 2>/dev/null
                 done | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[ (|].*//' | grep -vE '^$' \
                     | comm -23 - <(printf '%s\n' $built_pkgs) | tr '\n' ' ')
    # apt 的依赖闭包（只算硬依赖，避免把 Recommends 链带进来让 runtime 变大）
    closure=$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
                  --no-breaks --no-replaces --no-enhances $apt_roots $built_deps 2>/dev/null \
              | awk '/^[A-Za-z0-9]/ {print $1}' | sed 's/:.*//' | sort -u)
    pkgs=$(comm -23 <(printf '%s\n' "$closure") <(printf '%s\n' "$base_pkgs") | sort -u)
    pkgs=$(printf '%s\n' $pkgs $built_pkgs | sort -u)
    # 过滤掉虚拟包/没装上的包（它们没有文件可拷），其余照常处理
    real=""
    for pkg in $pkgs; do
        case " $built_pkgs " in
            *" $pkg "*) real="$real $pkg"; continue ;;
        esac
        if dpkg -L "$pkg" >/dev/null 2>&1; then real="$real $pkg"; fi
    done
    pkgs=$(printf '%s\n' $real)
fi

# 本仓库编译的 deb 解到临时目录，按包名取文件列表
built_root=
cleanup() {
    if [ -n "$built_root" ]; then rm -rf "$built_root"; fi
}
trap cleanup EXIT
for deb in "$deb_dir"/*.deb; do
    [ -e "$deb" ] || continue
    if [ -z "$built_root" ]; then built_root=$(mktemp -d); fi
    dpkg -x "$deb" "$built_root"
done

deb_of() {
    local deb
    for deb in "$deb_dir"/*.deb; do
        [ -e "$deb" ] || continue
        if [ "$(dpkg-deb -f "$deb" Package 2>/dev/null)" = "$1" ]; then
            printf '%s\n' "$deb"
            return 0
        fi
    done
    return 1
}

echo "- 开始构建Runtime: $(date '+%F %T')，共 $(printf '%s\n' "$pkgs" | grep -c .) 个包"
: >"$PREFIX/packages.list"

copied=0
for pkg in $pkgs; do
    if deb=$(deb_of "$pkg"); then
        files=$(dpkg -c "$deb" | awk '{print $6}' | sed 's#^\./#/#' | grep '^/')
        pkg_root=$built_root
        version=$(dpkg-deb -f "$deb" Version)
    else
        files=$(dpkg -L "$pkg" 2>/dev/null)
        pkg_root=$src_root
        version=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)
    fi
    if [ -z "$files" ]; then
        echo "  警告: $pkg 找不到文件列表，跳过"
        continue
    fi
    while IFS= read -r f; do
        case "$f" in
            /usr/share/applications/*|/usr/lib/systemd/*|/usr/share/systemd/*) continue ;;
            /usr/*) rel=${f#/usr} ;;
            # 没有 usrmerge 的老 deb 会把文件装在 /lib、/bin 下，原样放进 runtime
            /lib/*|/lib64/*|/bin/*|/sbin/*) rel=$f ;;
            *) continue ;;   # /etc、/var 不要
        esac
        if [ -d "$pkg_root$f" ]; then continue; fi
        if [ ! -e "$pkg_root$f" ]; then continue; fi
        mkdir -p "$PREFIX$(dirname "$rel")"
        cp -a "$pkg_root$f" "$PREFIX$rel"
        copied=$((copied + 1))
    done <<<"$files"
    echo "Package: $pkg ${version:-?}" >>"$PREFIX/packages.list"
done
echo "- 已拷贝 $copied 个文件"

# 1) .pc 文件里的 /usr 改成 runtime 前缀
find "$PREFIX" -path '*/pkgconfig/*.pc' -type f -print0 2>/dev/null \
    | xargs -0 -r sed -i "s#/usr#$PREFIX#g"

# 2) 绝对路径软链接：目标已经在 runtime 里，就指到 runtime 内部
find "$PREFIX" -type l 2>/dev/null | while IFS= read -r link; do
    target=$(readlink "$link")
    case "$target" in
        /lib/*|/lib64/*|/usr/*|/bin/*|/sbin/*)
            if [ -e "$PREFIX$target" ]; then
                ln -sfn "$PREFIX$target" "$link"
            fi
            ;;
    esac
done

# 3) 动态库 RUNPATH 里的 /usr 改成 runtime 前缀
#    容器里不一定装了 patchelf（v5 那次一条都没匹配到，所以一直没暴露），
#    没有就只报警告、跳过，别让跑到最后一步的构建白费。
if ! command -v patchelf >/dev/null 2>&1; then
    echo "警告: 容器里没有 patchelf，跳过 RUNPATH 改写" >&2
fi
find "$PREFIX" -type f \( -name '*.so' -o -name '*.so.*' \) -print0 2>/dev/null \
    | while IFS= read -r -d '' so; do
    runpath=$(readelf -d "$so" 2>/dev/null | sed -n 's/.*RUNPATH.*\[\(.*\)\]/\1/p')
    case "$runpath" in
        /usr/*)
            if command -v patchelf >/dev/null 2>&1; then
                patchelf --set-rpath "$PREFIX${runpath#/usr}" "$so"
            else
                echo "  警告: $so 的 RUNPATH 仍指向 $runpath" >&2
            fi
            ;;
    esac
done

# 4) 字体交给 base，runtime 不带
rm -rf "$PREFIX/share/fonts"

# 5) 关键库必须存在，缺了直接失败（避免又出现"构建成功但 runtime 缺库"）
for lib in libwebkit2gtk-4.1.so.0 libjavascriptcoregtk-4.1.so.0 \
           libgtk-4.so.1 libsoup-3.0.so.0; do
    if ! ls "$PREFIX"/lib/*/"$lib" >/dev/null 2>&1; then
        echo "错误: runtime 里缺少 $lib" >&2
        exit 1
    fi
done

# 6) 更新 ld.so 缓存
if [ -n "${LINGLONG_LD_SO_CACHE:-}" ]; then
    ldconfig -C "$LINGLONG_LD_SO_CACHE"
fi

echo "- Runtime 依赖安装完成: $(date '+%F %T')"
