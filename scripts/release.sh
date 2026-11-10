#!/usr/bin/env bash
# GitHub Release 管理。需要 gh CLI；在 Actions 中通过 GH_TOKEN / GH_REPO 环境变量认证。
#
# 用法：
#   release.sh status  --version V --pkgrel N --arches "amd64 arm64" [--force]
#       判断是否需要构建。stdout 输出 needed=true|false
#       （release 不存在、或缺少任何应有资产时为 true）
#   release.sh publish --version V --pkgrel N --arches "amd64 arm64" --dist 目录 [--target 提交]
#       生成 SHA256SUMS 和说明，创建/更新 release v<V>，并删除同名系列里过时的资产
#       （例如 pkgrel 变了之后的旧包）。
set -euo pipefail
. "$(dirname "$0")/common.sh"

(($#)) || die "用法: release.sh status|publish [选项]"
cmd=$1
shift
ver='' rel=$PKGREL_DEFAULT arches='' dist='' target='' force=0
while (($#)); do
  case $1 in
    --force) force=1; shift; continue ;;
  esac
  [[ $# -ge 2 ]] || die "$1 需要参数"
  case $1 in
    --version) ver=$2 ;; --pkgrel) rel=$2 ;; --arches) arches=$2 ;;
    --dist) dist=$2 ;; --target) target=$2 ;;
    *) die "未知参数: $1" ;;
  esac
  shift 2
done
is_version "$ver" || die "--version 格式不对: $ver"
is_pkgrel "$rel" || die "--pkgrel 必须是正整数"
read -r -a arch_list <<<"$arches"
((${#arch_list[@]})) || die "缺少 --arches"
need gh

tag="v$ver"
mapfile -t expected < <(expected_assets "$ver" "$rel" "${arch_list[@]}")

# 列出 release 已有的资产名；release 不存在时输出空，其他错误直接失败
existing_assets() {
  local out err
  err=$(mktemp)
  if out=$(gh release view "$tag" --json assets --jq '.assets[].name' 2>"$err"); then
    rm -f "$err"
    printf '%s\n' "$out"
    return 0
  fi
  if grep -qi 'not found' "$err"; then
    rm -f "$err"
    return 0
  fi
  cat "$err" >&2
  rm -f "$err"
  die "查询 release $tag 失败"
}

# shellcheck disable=SC2016  # 反引号是 Markdown 代码格式，不是命令替换
release_notes() {
  local a carch deb pkg rpm date
  date=$(date -u +%Y-%m-%d)
  cat <<EOF
Claude Desktop **$ver**，取自 Anthropic 官方 apt 仓库（$date 检查，签名校验通过）。

| 发行版 | 安装命令 |
|---|---|
EOF
  for a in "${arch_list[@]}"; do
    carch=$(deb_to_carch "$a")
    deb=$(asset_deb "$ver" "$a")
    pkg=$(asset_pacman "$ver" "$rel" "$carch")
    rpm=$(asset_rpm "$ver" "$rel" "$carch")
    printf '| Debian / Ubuntu（%s） | `sudo apt install ./%s` |\n' "$a" "$deb"
    printf '| Arch Linux（%s） | `sudo pacman -U ./%s` |\n' "$carch" "$pkg"
    printf '| Fedora / RHEL（%s） | `sudo dnf install ./%s` |\n' "$carch" "$rpm"
    printf '| openSUSE（%s） | `sudo zypper install --allow-unsigned-rpm ./%s` |\n' "$carch" "$rpm"
  done
  cat <<EOF

- \`.deb\` 是**官方原包**，未做任何修改，SHA256 与官方签名索引一致。安装后它会自动注册官方 apt 源，之后随 \`apt upgrade\` 更新。
- \`.pkg.tar.zst\` / \`.rpm\` 是由本仓库从官方 \`.deb\` 重新打包的**非官方**包，未签名，请用 \`SHA256SUMS\` 校验。
- 下载后校验：\`sha256sum -c SHA256SUMS --ignore-missing\`

官方 .deb SHA256：
EOF
  for a in "${arch_list[@]}"; do
    deb=$(asset_deb "$ver" "$a")
    printf -- '- `%s`  `%s`\n' "$(sha256_of "$dist/$deb")" "$deb"
  done
}

case $cmd in
  status)
    existing=$(existing_assets)
    missing=()
    for a in "${expected[@]}"; do
      grep -qxF -- "$a" <<<"$existing" || missing+=("$a")
    done
    if ((force)); then
      msg "手动强制重建 $tag"
      echo needed=true
    elif ((${#missing[@]})); then
      if [[ -z $existing ]]; then msg "release $tag 不存在，需要构建"; else msg "release $tag 缺少资产，需要重建"; fi
      for a in "${missing[@]}"; do info "缺少: $a"; done
      echo needed=true
    else
      msg "release $tag 已完整，无需构建"
      echo needed=false
    fi
    ;;

  publish)
    [[ -d $dist ]] || die "缺少 --dist 目录"
    files=()
    for a in "${expected[@]}"; do
      [[ $a == SHA256SUMS ]] && continue
      [[ -f $dist/$a ]] || die "构建产物缺失: $dist/$a"
      files+=("$dist/$a")
    done
    (cd "$dist" && sha256sum -- "${files[@]##*/}") >"$dist/SHA256SUMS"
    files+=("$dist/SHA256SUMS")
    notes=$(mktemp)
    trap 'rm -f "$notes"' EXIT
    release_notes >"$notes"

    existing=$(existing_assets)
    if [[ -n $existing ]] || gh release view "$tag" >/dev/null 2>&1; then
      msg "更新已有 release $tag"
      gh release upload "$tag" "${files[@]}" --clobber
      gh release edit "$tag" --title "Claude Desktop $ver" --notes-file "$notes"
    else
      msg "创建 release $tag"
      gh release create "$tag" "${files[@]}" --title "Claude Desktop $ver" \
        --notes-file "$notes" ${target:+--target "$target"}
    fi

    # 删除本系列中不再需要的旧资产（比如 pkgrel 变化后留下的旧包）
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      [[ $name =~ ^${PKGNAME}[-_].*\.(deb|rpm|pkg\.tar\.zst)$ ]] || continue
      printf '%s\n' "${expected[@]}" | grep -qxF -- "$name" && continue
      info "删除过时资产: $name"
      gh release delete-asset "$tag" "$name" --yes
    done < <(existing_assets)
    msg "release $tag 已发布"
    ;;

  *) die "未知子命令: $cmd（status|publish）" ;;
esac
