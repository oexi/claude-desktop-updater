#!/usr/bin/env bash
# 用官方 .deb 打出 RPM 包（Fedora / RHEL / openSUSE 等）。
# 可在 x86_64 主机上打 aarch64 包（rpmbuild --target）。
#
# 用法：build-rpm.sh --deb 文件 --sha256 哈希 --version 版本 --carch x86_64|aarch64
#                    [--release N] --outdir 目录
# 需要 rpmbuild、ar（binutils）、tar 及对应解压工具。stdout 输出生成的包路径。
set -euo pipefail
. "$(dirname "$0")/common.sh"

deb='' sha='' ver='' carch='' rel=$PKGREL_DEFAULT outdir=''
while (($#)); do
  [[ $# -ge 2 ]] || die "$1 需要参数"
  case $1 in
    --deb) deb=$2 ;; --sha256) sha=$2 ;; --version) ver=$2 ;;
    --carch) carch=$2 ;; --release|--pkgrel) rel=$2 ;; --outdir) outdir=$2 ;;
    *) die "未知参数: $1" ;;
  esac
  shift 2
done
[[ -f $deb ]] || die "找不到 .deb: ${deb:-（未指定）}"
is_sha256 "$sha" || die "--sha256 格式不对"
is_version "$ver" || die "--version 格式不对: $ver"
is_pkgrel "$rel" || die "--release 必须是正整数"
deb_arch=$(carch_to_deb "$carch") || die "--carch 只支持 x86_64 / aarch64"
[[ -n $outdir ]] || die "缺少 --outdir"
need rpmbuild ar tar sha256sum sed
[[ ${deb##*/} == "$(asset_deb "$ver" "$deb_arch")" ]] || die ".deb 文件名与版本/架构不符: ${deb##*/}"
[[ $(sha256_of "$deb") == "$sha" ]] || die ".deb 的 SHA256 与签名索引不符"

mkdir -p "$outdir"
outdir=$(cd "$outdir" && pwd)
deb=$(cd "$(dirname "$deb")" && pwd)/${deb##*/}
top=$(mktemp -d "${TMPDIR:-/tmp}/claude-desktop-rpm.XXXXXX")
trap 'rm -rf "$top"' EXIT
mkdir -p "$top"/{SOURCES,SPECS,BUILD,RPMS,SRPMS}

# ---------------------------------------------------------------- 取出 .deb 的文件负载
data=$(ar t "$deb" | grep -E '^data\.tar(\.[a-z0-9]+)?$' | head -n1) || true
[[ -n $data ]] || die ".deb 里找不到 data.tar.*"
(cd "$top/SOURCES" && ar x "$deb" "$data")
cp "$ROOT_DIR/packaging/common/claude-desktop.sh" "$top/SOURCES/claude-desktop.sh"

changelog_date=$(LC_ALL=C date -u '+%a %b %d %Y')
sed -e "s/@VERSION@/$ver/g" -e "s/@RELEASE@/$rel/g" -e "s/@DATA_TARBALL@/$data/" \
    -e "s/@CHANGELOG_DATE@/$changelog_date/" \
  "$ROOT_DIR/packaging/rpm/claude-desktop.spec.in" >"$top/SPECS/claude-desktop.spec"
grep -q '@[A-Z_0-9]*@' "$top/SPECS/claude-desktop.spec" && die "spec 仍有未替换的占位符"

# ---------------------------------------------------------------- rpmbuild
msg "打包 $PKGNAME $ver-$rel.$carch.rpm"
[[ $carch == "$(uname -m)" ]] || info "跨架构打包: $(uname -m) → $carch"
rpmbuild -bb --target "$carch" \
  --define "_topdir $top" \
  --define "_rpmfilename %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm" \
  "$top/SPECS/claude-desktop.spec" >&2 || die "rpmbuild 失败"

name=$(asset_rpm "$ver" "$rel" "$carch")
[[ -f $top/RPMS/$name ]] || die "rpmbuild 完成但找不到 $name"
mv -f "$top/RPMS/$name" "$outdir/$name"
msg "已生成 $outdir/$name"
printf '%s\n' "$outdir/$name"
