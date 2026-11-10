#!/usr/bin/env bash
# 用官方 .deb 打出 Arch Linux 的 pacman 包（.pkg.tar.zst）。
# 可在 x86_64 主机上打 aarch64 包：只是重新打包预编译文件，不涉及编译。
#
# 用法：build-pacman.sh --deb 文件 --sha256 哈希 --version 版本 --carch x86_64|aarch64
#                       [--pkgrel N] --outdir 目录
# 必须以普通用户运行（makepkg 的要求）。stdout 输出生成的包路径。
set -euo pipefail
. "$(dirname "$0")/common.sh"

deb='' sha='' ver='' carch='' rel=$PKGREL_DEFAULT outdir=''
while (($#)); do
  [[ $# -ge 2 ]] || die "$1 需要参数"
  case $1 in
    --deb) deb=$2 ;; --sha256) sha=$2 ;; --version) ver=$2 ;;
    --carch) carch=$2 ;; --pkgrel) rel=$2 ;; --outdir) outdir=$2 ;;
    *) die "未知参数: $1" ;;
  esac
  shift 2
done
[[ -f $deb ]] || die "找不到 .deb: ${deb:-（未指定）}"
is_sha256 "$sha" || die "--sha256 格式不对"
is_version "$ver" || die "--version 格式不对: $ver"
is_pkgrel "$rel" || die "--pkgrel 必须是正整数"
deb_arch=$(carch_to_deb "$carch") || die "--carch 只支持 x86_64 / aarch64"
[[ -n $outdir ]] || die "缺少 --outdir"
((EUID != 0)) || die "makepkg 不能以 root 运行，请换普通用户（CI 中用 runuser）"
need makepkg sha256sum sed
[[ ${deb##*/} == "$(asset_deb "$ver" "$deb_arch")" ]] || die ".deb 文件名与版本/架构不符: ${deb##*/}"
[[ $(sha256_of "$deb") == "$sha" ]] || die ".deb 的 SHA256 与签名索引不符"

mkdir -p "$outdir"
outdir=$(cd "$outdir" && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/claude-desktop-pacman.XXXXXX")
trap 'rm -rf "$build"' EXIT

# ---------------------------------------------------------------- 生成 PKGBUILD
cp "$ROOT_DIR/packaging/common/claude-desktop.sh" "$build/claude-desktop.sh"
sha_launcher=$(sha256_of "$build/claude-desktop.sh")
sha_x86_64=SKIP sha_aarch64=SKIP          # 只打本架构，另一架构的源不会被用到
printf -v "sha_$carch" '%s' "$sha"
sed -e "s/@PKGVER@/$ver/" -e "s/@PKGREL@/$rel/" \
    -e "s/@SHA_LAUNCHER@/$sha_launcher/" \
    -e "s/@SHA_X86_64@/$sha_x86_64/" -e "s/@SHA_AARCH64@/$sha_aarch64/" \
    "$ROOT_DIR/packaging/arch/PKGBUILD.in" >"$build/PKGBUILD"
grep -q '@[A-Z_0-9]*@' "$build/PKGBUILD" && die "PKGBUILD 仍有未替换的占位符"

# .deb 放进 startdir，makepkg 就不会再下载（仍会按 PKGBUILD 里的哈希校验）
cp "$deb" "$build/"

# ---------------------------------------------------------------- makepkg 配置
# 跨架构打包：复制系统配置并改 CARCH/CHOST，makepkg 便会选用 *_aarch64 的源和依赖
conf=/etc/makepkg.conf
if [[ $carch != "$(uname -m)" ]]; then
  sed -e "s/^CARCH=.*/CARCH=\"$carch\"/" -e "s/^CHOST=.*/CHOST=\"$carch-unknown-linux-gnu\"/" \
    /etc/makepkg.conf >"$build/makepkg.conf"
  conf="$build/makepkg.conf"
  info "跨架构打包: $(uname -m) → $carch"
fi

msg "打包 $PKGNAME $ver-$rel ($carch)"
cd "$build"
# -d：只是解包重打，不需要在打包机上装运行时依赖
MAKEPKG_CONF=$conf PKGDEST="$outdir" SRCDEST="$build" BUILDDIR="$build/work" \
  PKGEXT=.pkg.tar.zst makepkg -d -f --noconfirm >&2 || die "makepkg 失败"

pkg="$outdir/$(asset_pacman "$ver" "$rel" "$carch")"
[[ -f $pkg ]] || die "makepkg 完成但找不到 $pkg"
msg "已生成 $pkg"
printf '%s\n' "$pkg"
