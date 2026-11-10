#!/usr/bin/env bash
# 读取并校验 Anthropic 官方 apt 仓库，输出最新版本信息。
#
# 校验链：固定指纹的签名密钥 → InRelease 的 GPG 签名（及 Valid-Until）
#         → 各架构 Packages 索引的 SHA256 → 其中列出的 .deb SHA256
#
# 用法：check-upstream.sh [--arch amd64|arm64]...   （默认两个架构都查）
#
# stdout 输出 key=value（可直接追加到 $GITHUB_OUTPUT）：
#   version=4.23118.1                 所查架构中的最高版本
#   arches=amd64 arm64                已发布该版本的架构
#   deb_<arch>_url / _sha256 / _size  每个架构 .deb 的地址、哈希、大小
#   matrix=[{"deb":"amd64","carch":"x86_64","url":"…","sha256":"…"},…]
set -euo pipefail
. "$(dirname "$0")/common.sh"

arches=()
while (($#)); do
  case $1 in
    --arch) [[ $# -ge 2 ]] || die "--arch 需要参数"; arches+=("$2"); shift ;;
    -h|--help) sed -n '2,/^set -/{/^set -/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
  shift
done
((${#arches[@]})) || arches=(amd64 arm64)
for a in "${arches[@]}"; do deb_to_carch "$a" >/dev/null || die "不支持的架构: $a"; done

need curl gpg gpgv sha256sum awk sort date

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fetch() { curl -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1"; }

# 版本比较：Arch 上用 pacman 的 vercmp；其他环境用 dpkg 或 sort -V
vgt() { # vgt a b → a > b ?
  if command -v vercmp >/dev/null; then
    (( $(vercmp "$1" "$2") > 0 ))
  elif command -v dpkg >/dev/null; then
    dpkg --compare-versions "$1" gt "$2"
  else
    [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]
  fi
}

# ---------------------------------------------------------------- 签名校验
msg "获取 Anthropic apt 仓库索引（${arches[*]}）"
fetch "$KEY_URL" "$work/key.asc"                           || die "下载签名密钥失败: $KEY_URL"
fetch "$REPO_URL/dists/stable/InRelease" "$work/InRelease" || die "下载 InRelease 失败"

gnupg_home="$work/gnupg"
mkdir -m 700 "$gnupg_home"

# 密钥文件里必须只有一个主密钥，且指纹与官方文档一致
mapfile -t pub_fprs < <(gpg --homedir "$gnupg_home" --batch --show-keys --with-colons "$work/key.asc" 2>/dev/null \
  | awk -F: '$1=="pub"{want=1; next} want && $1=="fpr"{print $10; want=0}')
[[ ${#pub_fprs[@]} -eq 1 && ${pub_fprs[0]} == "$KEY_FPR" ]] \
  || die "签名密钥指纹不符（期望 $KEY_FPR，得到 ${pub_fprs[*]:-无}）"
gpg --homedir "$gnupg_home" --batch --dearmor <"$work/key.asc" >"$work/key.gpg"

# gpgv 校验 InRelease，并取出签名覆盖的正文（之后只信任这部分）
status=$(gpgv --homedir "$gnupg_home" --keyring "$work/key.gpg" --status-fd 1 \
              --output "$work/Release" "$work/InRelease" 2>/dev/null) \
  || die "InRelease 签名校验失败"
grep -Eq "^\[GNUPG:\] VALIDSIG .* $KEY_FPR\$" <<<"$status" \
  || die "InRelease 不是由 $KEY_FPR 签名的"

valid_until=$(awk -F': ' '$1=="Valid-Until"{print $2; exit}' "$work/Release")
if [[ -n $valid_until ]]; then
  vu_ts=$(date -d "$valid_until" +%s 2>/dev/null) || die "无法解析 Valid-Until: $valid_until"
  (( vu_ts > $(date +%s) )) || die "仓库索引已过期（Valid-Until: $valid_until）"
fi

# ---------------------------------------------------------------- 各架构最新版本
declare -A A_VER A_FILE A_SHA A_SIZE
for a in "${arches[@]}"; do
  fetch "$REPO_URL/dists/stable/main/binary-$a/Packages" "$work/Packages-$a" \
    || die "下载 $a 的 Packages 索引失败"
  want=$(awk -v f="main/binary-$a/Packages" '
    /^[^ ]/ { insec = ($0 == "SHA256:"); next }
    insec && $3 == f { print $1; exit }' "$work/Release")
  is_sha256 "$want" || die "InRelease 中找不到 $a Packages 的 SHA256"
  [[ $(sha256_of "$work/Packages-$a") == "$want" ]] || die "$a Packages 索引哈希不符"

  best_v='' best_f='' best_s='' best_z=''
  while read -r v f s z; do
    if [[ -z $best_v ]] || vgt "$v" "$best_v"; then
      best_v=$v best_f=$f best_s=$s best_z=$z
    fi
  done < <(awk -v pkg="$PKGNAME" -v RS='' -F'\n' '{
      p = v = f = s = z = ""
      for (i = 1; i <= NF; i++) {
        n = index($i, ": "); if (!n) continue
        k = substr($i, 1, n - 1); val = substr($i, n + 2)
        if (k == "Package")  p = val
        if (k == "Version")  v = val
        if (k == "Filename") f = val
        if (k == "SHA256")   s = val
        if (k == "Size")     z = val
      }
      if (p == pkg && v != "" && f != "" && s != "") print v, f, s, z
    }' "$work/Packages-$a")

  [[ -n $best_v ]] || { warn "$a 索引中没有 $PKGNAME"; continue; }
  is_version "$best_v" || die "$a 上游版本号 '$best_v' 含不支持的字符，需要人工处理"
  [[ $best_f == "pool/main/c/$PKGNAME/$(asset_deb "$best_v" "$a")" ]] \
    || die "$a 上游文件路径与预期不符: $best_f"
  is_sha256 "$best_s" || die "$a 索引中的 SHA256 格式不对"
  [[ $best_z =~ ^[0-9]+$ ]] || best_z=0

  A_VER[$a]=$best_v A_FILE[$a]=$best_f A_SHA[$a]=$best_s A_SIZE[$a]=$best_z
  info "$a 最新: $best_v"
done

version=''
for a in "${!A_VER[@]}"; do
  if [[ -z $version ]] || vgt "${A_VER[$a]}" "$version"; then version=${A_VER[$a]}; fi
done
[[ -n $version ]] || die "所有架构的索引里都没有 $PKGNAME"

# ---------------------------------------------------------------- 输出
ready=() matrix=''
for a in "${arches[@]}"; do
  [[ ${A_VER[$a]:-} == "$version" ]] || { warn "$a 还没有 $version，本次跳过该架构"; continue; }
  ready+=("$a")
  url="$REPO_URL/${A_FILE[$a]}"
  printf 'deb_%s_url=%s\n'    "$a" "$url"
  printf 'deb_%s_sha256=%s\n' "$a" "${A_SHA[$a]}"
  printf 'deb_%s_size=%s\n'   "$a" "${A_SIZE[$a]}"
  matrix+="${matrix:+,}{\"deb\":\"$a\",\"carch\":\"$(deb_to_carch "$a")\",\"url\":\"$url\",\"sha256\":\"${A_SHA[$a]}\"}"
done
printf 'version=%s\n' "$version"
printf 'arches=%s\n' "${ready[*]}"
printf 'matrix=[%s]\n' "$matrix"
msg "签名校验通过，最新版本 $version（${ready[*]}）"
