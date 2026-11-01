#!/usr/bin/env bash
# Release-pinned installer for vps-proxy-setup (detailed design 2.9). It
# installs /usr/local/bin/vps-proxy-setup, the modules in
# /usr/local/lib/vps-proxy-setup and the data files in
# /usr/local/share/vps-proxy-setup, after checking every file against
# SHA256SUMS and SHA256SUMS against the digest pinned below. It never runs
# deploy, check or target-check.

set -Eeuo pipefail
umask 077
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
LC_ALL=C
export PATH LC_ALL

# Set together at each release; tests/static.sh checks the version and the
# asset lists against bin/vps-proxy-setup and share/vps-proxy-setup. An empty
# digest means this copy is not bound to a release and installs nothing.
INSTALLER_VERSION='0.1.0'
RELEASE_TAG='v0.1.0'
REPOSITORY='alieismy/vps-proxy-setup'
EXPECTED_MANIFEST_SHA256=''

readonly BIN_PATH=/usr/local/bin/vps-proxy-setup
readonly LIB_PARENT=/usr/local/lib
readonly LIB_DIR="$LIB_PARENT/vps-proxy-setup"
readonly SHARE_PARENT=/usr/local/share
readonly SHARE_DIR="$SHARE_PARENT/vps-proxy-setup"
readonly LOCK_FILE=/run/vps-proxy-setup.lock

# Release assets, flat. The first is the command; the rest are its modules.
assets=(
  vps-proxy-setup
  common.sh
  pins.sh
  platform.sh
  inputs.sh
  probe.sh
  xuidb.sh
  preflight.sh
  check.sh
  target.sh
  deploy.sh
)
# Data files for /usr/local/share/vps-proxy-setup; the rules text comes in M2
# and the cloudflared unit in M3.
data_assets=()

source_dir=''
temp_dir=''
lib_stage=''
share_stage=''
old_lib=''
old_share=''
bin_tmp=''
old_bin=''
swapping=0

info() { printf '[vps-proxy-setup-install] %s\n' "$*"; }
die() {
  printf '[vps-proxy-setup-install][x] %s\n' "$*" >&2
  exit 1
}
usage_die() {
  printf '[vps-proxy-setup-install][x] %s\n' "$*" >&2
  printf '    用法见 bash install.sh --help\n' >&2
  exit 2
}

# restore_dir DIR STAGE OLD: put back one directory from before this run.
# Whether a rename happened is read from the files, not from a variable, so a
# signal right after a rename is handled the same way.
restore_dir() {
  if [ ! -e "$2" ]; then
    rm -rf -- "$1" || return 1
  fi
  if [ -n "$3" ] && [ -d "$3" ]; then
    mv -T -- "$3" "$1" || return 1
  fi
}

# Put back the command, modules and data files from before this run; 1 if a
# step fails.
restore_previous() {
  if [ ! -e "$bin_tmp" ]; then
    if [ -n "$old_bin" ]; then
      mv -f -- "$old_bin" "$BIN_PATH" || return 1
    else
      rm -f -- "$BIN_PATH" || return 1
    fi
  fi
  restore_dir "$LIB_DIR" "$lib_stage" "$old_lib" || return 1
  restore_dir "$SHARE_DIR" "$share_stage" "$old_share" || return 1
}

# Until the new files are in place and run, a failure or signal puts the
# previous ones back; the install either completes or changes nothing.
cleanup() {
  trap '' INT TERM HUP
  if [ "$swapping" -eq 1 ]; then
    if restore_previous; then
      info '安装未完成，已恢复为安装前的状态'
    else
      printf '[vps-proxy-setup-install][x] %s\n' "安装未完成，恢复安装前的文件时出错；安装前的入口、模块和数据文件保留在 ${old_bin:-（无）}、${old_lib:-（无）}、${old_share:-（无）}" >&2
      old_bin=''
      old_lib=''
      old_share=''
    fi
  fi
  [ -z "$lib_stage" ] || rm -rf -- "$lib_stage"
  [ -z "$share_stage" ] || rm -rf -- "$share_stage"
  [ -z "$bin_tmp" ] || rm -f -- "$bin_tmp"
  [ -z "$old_lib" ] || rm -rf -- "$old_lib"
  [ -z "$old_share" ] || rm -rf -- "$old_share"
  [ -z "$old_bin" ] || rm -f -- "$old_bin"
  [ -z "$temp_dir" ] || rm -rf -- "$temp_dir"
}

usage() {
  cat <<EOF
用法：
  bash install.sh
  bash install.sh --source-dir /绝对路径/发行版资产

远程方式只下载固定的 $RELEASE_TAG 发行版：先用本脚本内置的摘要校验 SHA256SUMS，
再用 SHA256SUMS 校验每个资产。本地方式用于发行前验证，目录中须有同样的资产和
SHA256SUMS，同样要通过内置摘要的校验。安装只放置文件，不执行 deploy、check 或
target-check。另一个 vps-proxy-setup 部署或安装正在进行时，拒绝安装。
EOF
}

download_file() {
  curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 120 --max-redirs 5 --output "$2" "$1"
}

file_sha256() {
  sha256sum <"$1" | awk '{print $1}'
}

# The manifest lists exactly the assets, each once, as "DIGEST  NAME".
manifest_valid() {
  local name
  [ "$(awk 'NF' "$1" | wc -l)" -eq $((${#assets[@]} + ${#data_assets[@]})) ] || return 1
  # No regex interval: mawk does not support {64} (detailed design 8).
  for name in "${assets[@]}" "${data_assets[@]}"; do
    [ "$(awk -v name="$name" '$2 == name && length($1) == 64 && $1 !~ /[^0-9a-f]/ && NF == 2 { n++ } END { print n + 0 }' "$1")" -eq 1 ] ||
      return 1
  done
}

manifest_digest() {
  awk -v name="$2" '$2 == name { print $1; exit }' "$1"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source-dir)
        [ "$#" -ge 2 ] || usage_die '--source-dir 缺少取值'
        source_dir="$2"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) usage_die "未知参数：$1" ;;
    esac
  done
}

# dir_matches DIR NAME...: DIR holds exactly NAME..., each root-owned 0644
# and identical to the release.
dir_matches() {
  local dir="$1" name
  shift
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  [ "$(stat -c '%u:%g:%a' -- "$dir")" = '0:0:755' ] || return 1
  [ "$(find "$dir" -mindepth 1 | wc -l)" -eq "$#" ] || return 1
  for name in "$@"; do
    [ -f "$dir/$name" ] && [ ! -L "$dir/$name" ] || return 1
    [ "$(stat -c '%u:%g:%a' -- "$dir/$name")" = '0:0:644' ] || return 1
    [ "$(file_sha256 "$dir/$name")" = "$(manifest_digest "$temp_dir/SHA256SUMS" "$name")" ] || return 1
  done
}

# True when the installed files are exactly this release, with the owners and
# modes this script gives them.
already_installed() {
  [ -f "$BIN_PATH" ] && [ ! -L "$BIN_PATH" ] || return 1
  [ "$(stat -c '%u:%g:%a' -- "$BIN_PATH")" = '0:0:755' ] || return 1
  [ "$(file_sha256 "$BIN_PATH")" = "$(manifest_digest "$temp_dir/SHA256SUMS" vps-proxy-setup)" ] || return 1
  dir_matches "$LIB_DIR" "${assets[@]:1}" || return 1
  dir_matches "$SHARE_DIR" "${data_assets[@]}"
}

# stage_files STAGE FILE...: a 0755 directory next to the target holding the
# files at 0644. Called in the main shell so that a failure stops the install.
stage_files() {
  local stage="$1" name
  shift
  install -d -o root -g root -m 0755 "$stage"
  for name in "$@"; do
    install -o root -g root -m 0644 "$temp_dir/assets/$name" "$stage/$name"
  done
}

main() {
  local command name base got
  parse_args "$@"
  [ "$(id -u)" -eq 0 ] || die '需要 root 权限：请在 root shell 中运行'
  for command in awk cp curl find flock grep install mktemp mv rm sha256sum stat sync wc; do
    [ -n "$source_dir" ] && [ "$command" = curl ] && continue
    command -v "$command" >/dev/null 2>&1 || die "缺少命令：$command"
  done
  [ "$RELEASE_TAG" = "v$INSTALLER_VERSION" ] || die '安装脚本的版本与发行版标签不一致'
  [[ "$EXPECTED_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
    die '这份安装脚本没有绑定发行版（内置摘要为空）；请使用发行版附带的 install.sh'
  if [ -n "$source_dir" ]; then
    [[ "$source_dir" = /* ]] || usage_die '--source-dir 必须是绝对路径'
    [ -d "$source_dir" ] && [ ! -L "$source_dir" ] || die '--source-dir 不存在，或是符号链接'
  fi

  # The tool's own lock (detailed design 2.1): no deploy runs while the files change.
  exec 9>>"$LOCK_FILE"
  flock -n 9 || die '另一个 vps-proxy-setup 部署或安装正在进行，请稍后再试'

  temp_dir="$(mktemp -d)" || die '无法创建临时目录'
  trap cleanup EXIT
  trap 'exit 1' INT TERM HUP
  mkdir -m 0700 "$temp_dir/assets"
  if [ -n "$source_dir" ]; then
    [ -f "$source_dir/SHA256SUMS" ] && [ ! -L "$source_dir/SHA256SUMS" ] || die '资产目录中没有 SHA256SUMS'
    cp -- "$source_dir/SHA256SUMS" "$temp_dir/SHA256SUMS"
  else
    base="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG"
    info "下载 $RELEASE_TAG 的 SHA256SUMS"
    download_file "$base/SHA256SUMS" "$temp_dir/SHA256SUMS" || die '无法下载 SHA256SUMS；不会改用其他版本'
  fi
  got="$(file_sha256 "$temp_dir/SHA256SUMS")"
  [ "$got" = "$EXPECTED_MANIFEST_SHA256" ] || die "SHA256SUMS 的摘要 $got 与安装脚本内置的不一致"
  manifest_valid "$temp_dir/SHA256SUMS" || die 'SHA256SUMS 的内容与安装脚本的资产清单不一致'

  for name in "${assets[@]}" "${data_assets[@]}"; do
    if [ -n "$source_dir" ]; then
      [ -f "$source_dir/$name" ] && [ ! -L "$source_dir/$name" ] || die "资产目录中没有 $name"
      cp -- "$source_dir/$name" "$temp_dir/assets/$name"
    else
      info "下载 $name"
      download_file "$base/$name" "$temp_dir/assets/$name" || die "无法下载 $name"
    fi
    [ "$(file_sha256 "$temp_dir/assets/$name")" = "$(manifest_digest "$temp_dir/SHA256SUMS" "$name")" ] ||
      die "$name 未通过 SHA-256 校验"
  done
  grep -Fqx "readonly VPS_VERSION='$INSTALLER_VERSION'" "$temp_dir/assets/vps-proxy-setup" ||
    die "vps-proxy-setup 的版本不是 $INSTALLER_VERSION"

  if already_installed; then
    info "已安装 vps-proxy-setup $INSTALLER_VERSION，文件与发行版一致，未做变更"
    exit 0
  fi
  for name in "$LIB_DIR" "$SHARE_DIR"; do
    if [ -L "$name" ] || { [ -e "$name" ] && [ ! -d "$name" ]; }; then
      die "$name 不是普通目录"
    fi
  done
  # A symbolic link is refused, as for the directories; a dangling one would
  # also escape the backup below and be lost on a rollback.
  if [ -L "$BIN_PATH" ] || { [ -e "$BIN_PATH" ] && [ ! -f "$BIN_PATH" ]; }; then
    die "$BIN_PATH 不是普通文件"
  fi

  install -d -o root -g root -m 0755 /usr/local/bin "$LIB_PARENT" "$SHARE_PARENT"
  # Assigned before staging so that cleanup removes a partly staged directory.
  lib_stage="$LIB_PARENT/.vps-proxy-setup.stage.$$"
  share_stage="$SHARE_PARENT/.vps-proxy-setup.stage.$$"
  stage_files "$lib_stage" "${assets[@]:1}"
  stage_files "$share_stage" "${data_assets[@]}"
  bin_tmp="/usr/local/bin/.vps-proxy-setup.new.$$"
  install -o root -g root -m 0755 "$temp_dir/assets/vps-proxy-setup" "$bin_tmp"

  if [ -e "$BIN_PATH" ]; then
    old_bin="/usr/local/bin/.vps-proxy-setup.old.$$"
    cp -a -- "$BIN_PATH" "$old_bin"
  fi
  swapping=1
  if [ -d "$LIB_DIR" ]; then
    old_lib="$LIB_PARENT/.vps-proxy-setup.old.$$"
    mv -T -- "$LIB_DIR" "$old_lib"
  fi
  mv -T -- "$lib_stage" "$LIB_DIR"
  if [ -d "$SHARE_DIR" ]; then
    old_share="$SHARE_PARENT/.vps-proxy-setup.old.$$"
    mv -T -- "$SHARE_DIR" "$old_share"
  fi
  mv -T -- "$share_stage" "$SHARE_DIR"
  mv -f -- "$bin_tmp" "$BIN_PATH"
  got="$("$BIN_PATH" --version)" || die '安装后无法运行 vps-proxy-setup --version'
  [ "$got" = "vps-proxy-setup $INSTALLER_VERSION" ] || die "安装后的版本为 $got"
  sync
  swapping=0
  lib_stage=''
  share_stage=''
  bin_tmp=''
  [ -z "$old_lib" ] || rm -rf -- "$old_lib"
  [ -z "$old_share" ] || rm -rf -- "$old_share"
  [ -z "$old_bin" ] || rm -f -- "$old_bin"
  old_lib=''
  old_share=''
  old_bin=''
  info "安装完成：$BIN_PATH（模块在 $LIB_DIR，数据文件在 $SHARE_DIR），版本 $INSTALLER_VERSION"
  info '安装没有执行 deploy、check 或 target-check。下一步：先用 vps-proxy-setup target-check <主机名> 核实候选的 REALITY target，再执行 vps-proxy-setup deploy'
}

main "$@"
