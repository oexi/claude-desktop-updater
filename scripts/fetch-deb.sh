#!/usr/bin/env bash
# 下载官方 .deb 并按（签名索引给出的）SHA256 校验。已存在且哈希正确则跳过下载。
#
# 用法：fetch-deb.sh URL SHA256 目标目录
# stdout 输出下载好的文件路径。
set -euo pipefail
. "$(dirname "$0")/common.sh"

[[ $# -eq 3 ]] || die "用法: fetch-deb.sh URL SHA256 目标目录"
url=$1 sha=$2 dest=$3
[[ $url == "$REPO_URL/pool/"*.deb ]] || die "只接受官方仓库 pool 下的 .deb: $url"
is_sha256 "$sha" || die "SHA256 格式不对: $sha"
need curl sha256sum

mkdir -p "$dest"
file="$dest/${url##*/}"

if [[ -f $file && $(sha256_of "$file") == "$sha" ]]; then
  info "已存在且校验通过: $file"
else
  msg "下载 ${url##*/}"
  curl -fL --retry 3 --connect-timeout 15 --progress-bar -o "$file.part" "$url" \
    || { rm -f "$file.part"; die "下载失败: $url"; }
  got=$(sha256_of "$file.part")
  [[ $got == "$sha" ]] || { rm -f "$file.part"; die "SHA256 不符（期望 $sha，得到 $got）"; }
  mv -f "$file.part" "$file"
  info "SHA256 校验通过"
fi
printf '%s\n' "$file"
