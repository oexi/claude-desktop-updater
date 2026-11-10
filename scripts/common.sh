# shellcheck shell=bash
# shellcheck disable=SC2034  # 这里定义的常量由 source 本文件的脚本使用
# 各脚本共享的常量与函数。用法：. "$(dirname "$0")/common.sh"

readonly PKGNAME="claude-desktop"
readonly REPO_URL="https://downloads.claude.ai/claude-desktop/apt/stable"
readonly KEY_URL="https://downloads.claude.ai/claude-desktop/key.asc"
# 官方文档给出的签名密钥指纹：https://code.claude.com/docs/en/desktop-linux
readonly KEY_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"

# 仓库根目录（scripts/ 的上一级）
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR

# 打包修订号（pkgrel / rpm Release）。打包方式（PKGBUILD / spec / 启动器）改动时 +1：
# 资产文件名随之变化，CI 下次运行会自动重建并删掉旧包。
PKGREL_DEFAULT=$(tr -d '[:space:]' <"$ROOT_DIR/packaging/PKGREL")
readonly PKGREL_DEFAULT

# ---------------------------------------------------------------- 输出（全部写 stderr，stdout 留给数据）
if [[ -t 2 ]]; then
  c_b=$'\e[1m' c_g=$'\e[32m' c_y=$'\e[33m' c_r=$'\e[31m' c_0=$'\e[0m'
else
  c_b='' c_g='' c_y='' c_r='' c_0=''
fi
msg()  { printf '%s==>%s %s%s\n' "$c_g$c_b" "$c_0$c_b" "$*" "$c_0" >&2; }
info() { printf '  %s->%s %s\n' "$c_b" "$c_0" "$*" >&2; }
warn() { printf '%s==> 警告:%s %s\n' "$c_y$c_b" "$c_0" "$*" >&2; }
die()  { printf '%s==> 错误:%s %s\n' "$c_r$c_b" "$c_0" "$*" >&2; exit 1; }

need() {
  local cmd
  for cmd; do command -v "$cmd" >/dev/null || die "缺少命令: $cmd"; done
}

# ---------------------------------------------------------------- 架构映射
deb_to_carch() {
  case $1 in
    amd64) echo x86_64 ;;
    arm64) echo aarch64 ;;
    *) return 1 ;;
  esac
}
carch_to_deb() {
  case $1 in
    x86_64) echo amd64 ;;
    aarch64) echo arm64 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------- 校验
is_sha256()  { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }
# 上游版本号要能直接当 pkgver / rpm Version 用，也要能安全地拼进文件名
is_version() { [[ $1 =~ ^[0-9][0-9A-Za-z.+]*$ ]]; }
is_pkgrel()  { [[ $1 =~ ^[1-9][0-9]*$ ]]; }

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# ---------------------------------------------------------------- release 资产命名（唯一定义处）
asset_deb()    { printf '%s_%s_%s.deb\n' "$PKGNAME" "$1" "$2"; }               # 版本 deb架构
asset_pacman() { printf '%s-%s-%s-%s.pkg.tar.zst\n' "$PKGNAME" "$1" "$2" "$3"; } # 版本 pkgrel carch
asset_rpm()    { printf '%s-%s-%s.%s.rpm\n' "$PKGNAME" "$1" "$2" "$3"; }        # 版本 release carch

# 某版本、某些 deb 架构下 release 应有的全部资产名
expected_assets() { # expected_assets 版本 pkgrel deb架构...
  local ver=$1 rel=$2 a carch
  shift 2
  for a; do
    carch=$(deb_to_carch "$a") || die "未知架构: $a"
    asset_deb "$ver" "$a"
    asset_pacman "$ver" "$rel" "$carch"
    asset_rpm "$ver" "$rel" "$carch"
  done
  echo SHA256SUMS
}
