#!/bin/sh
# Linux-only outer bootstrap. Called by STEMwerk_Bootstrap_Linux.sh.
set -uf
umask 022
LC_ALL=C
export LC_ALL

reaper=$1
shift
root=
custom_archive=
while [ "$#" -ge 2 ]; do
  case "${1:-}" in
    --root)
      root=$2
      shift 2
      ;;
    --archive)
      custom_archive=$2
      shift 2
      ;;
    --)
      break
      ;;
    *)
      break
      ;;
  esac
done
if [ -z "$root" ] || [ "${1:-}" != -- ] || [ "$#" -lt 2 ]; then
  printf '%s\n' 'usage: --managed-python-bootstrap --root ABSOLUTE_ROOT [--archive ARCHIVE_PATH] -- CORE_ARGUMENTS' >&2
  exit 2
fi
shift
src=$reaper/vendor/stemwerk-core/src
manifest=$src/stemwerk_core/runtime-manifest.v1.tsv
tab=$(printf '\t')
cr=$(printf '\r')
opdir=
stage=
seq=0
dlpid=

safe_dir() {
  case $1 in /*) ;; *) return 1 ;; esac
  case $1/ in */../*|*/./*|*'//'*) return 1 ;; esac
  part=
  oldifs=$IFS
  IFS=/
  for component in $1; do
    [ -n "$component" ] || continue
    part=$part/$component
    [ ! -L "$part" ] || { IFS=$oldifs; return 1; }
    if [ ! -d "$part" ]; then
      [ ! -e "$part" ] || { IFS=$oldifs; return 1; }
      mkdir -m 700 "$part" 2>/dev/null || [ -d "$part" ] || { IFS=$oldifs; return 1; }
      [ ! -L "$part" ] || { IFS=$oldifs; return 1; }
    fi
  done
  IFS=$oldifs
}

event() {
  seq=$((seq + 1))
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  payload=$2
  if [ "$1" = active_indeterminate ]; then
    payload="\"since_seconds\":$(( $(date +%s) - started_at ))"
  fi
  printf '{"protocol":"stemwerk-install-events/1","operation_id":"%s","seq":%s,"ts":"%s","source":"outer_layer","state":"%s","phase":"bootstrap",%s}\n' \
    "$op" "$seq" "$timestamp" "$1" "$payload" >> "$opdir/events.ndjson"
}

fail() {
  code=$1
  detail=$2
  action=$3
  if [ -n "$dlpid" ]; then
    kill "$dlpid" 2>/dev/null || :
    wait "$dlpid" 2>/dev/null || :
    dlpid=
  fi
  if [ -n "$opdir" ]; then
    event failed "\"error_code\":\"$code\",\"detail\":\"$detail\",\"action\":\"$action\""
    printf '{"protocol":"stemwerk-install-result/1","operation_id":"%s","exit_code":2,"stream":"stderr","document":{"kind":"stemwerk_module_install_error","schema_version":"1.0.0","error":{"code":"%s","message":"%s","module":null}}}\n' \
      "$op" "$code" "$detail" > "$opdir/.result.tmp"
    ln "$opdir/.result.tmp" "$opdir/result.json" || :
    rm -f "$opdir/.result.tmp"
  fi
  if [ -n "$stage" ] && [ -d "$stage" ] && [ ! -L "$stage" ]; then
    rm -rf -- "$stage"
  fi
  printf '{"kind":"stemwerk_module_install_error","schema_version":"1.0.0","error":{"code":"%s","message":"%s","module":null}}\n' "$code" "$detail" >&2
  exit 2
}

# A private target may sit below /tmp: a sticky, root-owned parent protects
# a user-owned child from other users, while a writable non-sticky parent does not.
private_path() {
  check_path=$1
  is_target=1
  while :; do
    [ -d "$check_path" ] && [ ! -L "$check_path" ] || return 1
    # shellcheck disable=SC2046
    set -- $(stat -c '%u %a' -- "$check_path") || return 1
    [ "$#" = 2 ] || return 1
    owner=$1
    mode=$2
    case $owner:$mode in *[!0-9:]*|:*) return 1 ;; esac
    permissions=$((0$mode))
    if [ "$is_target" = 1 ]; then
      [ "$owner" = "$my_uid" ] && [ $((permissions & 0022)) = 0 ] || return 1
    else
      { [ "$owner" = "$my_uid" ] || [ "$owner" = 0 ]; } || return 1
      if [ $((permissions & 0022)) != 0 ] && [ $((permissions & 01000)) = 0 ]; then return 1; fi
    fi
    [ "$check_path" = / ] && break
    check_path=${check_path%/*}
    [ -n "$check_path" ] || check_path=/
    is_target=0
  done
}

case $root in /*) ;; *) fail root_invalid 'Root must be absolute' 'Choose an absolute private root' ;; esac
root=${root%/}
[ -n "$root" ] || root=/
if ! command -v stat >/dev/null 2>&1 || ! command -v id >/dev/null 2>&1; then
  fail bootstrap_prerequisite_unavailable 'stat or id is unavailable' 'Install standard Linux account tools'
fi
my_uid=$(id -u) || fail bootstrap_prerequisite_unavailable 'Cannot determine current user' 'Check account tools'
safe_dir "$root" || fail root_unavailable 'Root path is unavailable or contains a link' 'Choose a private root without links'
private_path "$root" || fail root_not_private 'Root or ancestor is not private to this user' 'Choose a user-owned root without shared writes'
safe_dir "$root/logs" || fail operation_log_unavailable 'Cannot create operation logs directory' 'Check root permissions'
private_path "$root/logs" || fail root_not_private 'Operation logs directory is not private' 'Choose a user-owned root without shared writes'
op=$(cat /proc/sys/kernel/random/uuid) || fail operation_id_unavailable 'Cannot create operation identifier' 'Check Linux proc access'
candidate_opdir=$root/logs/$op
mkdir -m 700 "$candidate_opdir" || fail operation_log_unavailable 'Cannot create operation log' 'Check root permissions'
opdir=$candidate_opdir
started_at=$(date +%s)
event active_indeterminate '"since_seconds":0'
trap 'fail cancelled "Bootstrap was interrupted" "Start a new operation"' HUP INT TERM

[ -f "$manifest" ] && [ ! -L "$manifest" ] || fail manifest_unavailable 'The pinned manifest is unavailable' 'Restore the shipped Core files'
[ "$(tail -c 1 "$manifest" | od -An -tu1 | tr -d '[:space:]')" = 10 ] || fail manifest_invalid 'Manifest must end in LF' 'Restore the shipped manifest'
parse_manifest() {
first=1
linux=0
darwin=0
windows=0
name=
url=
size=
sha=
while IFS= read -r line; do
  if [ "$first" = 1 ]; then
    [ "$line" = 'stemwerk-runtime-manifest/1' ] || fail manifest_invalid 'Manifest protocol is invalid' 'Restore the shipped manifest'
    first=0
    continue
  fi
  case $line in ''|*' '*|*"$cr"*) fail manifest_invalid 'Manifest record is malformed' 'Restore the shipped manifest' ;; esac
  oldifs=$IFS
  IFS=$tab
  # Exactly five fields are required; reconstruction below detects empty fields.
  # shellcheck disable=SC2086
  set -- $line
  IFS=$oldifs
  [ "$#" = 5 ] && [ "$line" = "$1$tab$2$tab$3$tab$4$tab$5" ] || fail manifest_invalid 'Manifest record fields are malformed' 'Restore the shipped manifest'
  platform=$1
  pin=$2
  link=$3
  bytes=$4
  digest=$5
  case $platform in
    linux-x86_64) [ "$linux" = 0 ] || fail manifest_invalid 'Duplicate Linux pin' 'Restore the shipped manifest'; linux=1; target=x86_64-unknown-linux-gnu ;;
    darwin-arm64) [ "$darwin" = 0 ] || fail manifest_invalid 'Duplicate macOS pin' 'Restore the shipped manifest'; darwin=1; target=aarch64-apple-darwin ;;
    win-x86_64) [ "$windows" = 0 ] || fail manifest_invalid 'Duplicate Windows pin' 'Restore the shipped manifest'; windows=1; target=x86_64-pc-windows-msvc ;;
    *) fail manifest_invalid 'Unknown manifest platform' 'Restore the shipped manifest' ;;
  esac
  case $pin in python-3.12.*-????????) ;; *) fail manifest_invalid 'Invalid Python pin name' 'Restore the shipped manifest' ;; esac
  version=${pin#python-}
  version=${version%-*}
  patch=${version#3.12.}
  build=${pin##*-}
  case $patch in ''|*[!0-9]*) fail manifest_invalid 'Invalid Python patch version' 'Restore the shipped manifest' ;; esac
  [ "${#patch}" -le 3 ] || fail manifest_invalid 'Invalid Python patch version' 'Restore the shipped manifest'
  case $patch in 0|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;; *) fail manifest_invalid 'Invalid Python patch version' 'Restore the shipped manifest' ;; esac
  case $build in *[!0-9]*) fail manifest_invalid 'Invalid build date' 'Restore the shipped manifest' ;; esac
  expected=https://github.com/astral-sh/python-build-standalone/releases/download/$build/cpython-$version%2B$build-$target-install_only_stripped.tar.gz
  [ "$link" = "$expected" ] || fail manifest_invalid 'Manifest URL does not match pin' 'Restore the shipped manifest'
  case $bytes in ''|0*|*[!0-9]*) fail manifest_invalid 'Invalid archive size' 'Restore the shipped manifest' ;; esac
  [ "${#bytes}" -le 12 ] || fail manifest_invalid 'Invalid archive size' 'Restore the shipped manifest'
  [ "${#digest}" = 64 ] || fail manifest_invalid 'Invalid SHA-256 length' 'Restore the shipped manifest'
  case $digest in *[!0-9a-f]*) fail manifest_invalid 'Invalid SHA-256' 'Restore the shipped manifest' ;; esac
  if [ "$platform" = linux-x86_64 ]; then name=$pin; url=$link; size=$bytes; sha=$digest; fi
done < "$manifest"
[ "$first" = 0 ] && [ "$linux" = 1 ] && [ "$darwin" = 1 ] && [ "$windows" = 1 ] || fail manifest_invalid 'Manifest is incomplete' 'Restore the shipped manifest'
}
parse_manifest
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || fail platform_unsupported 'This Linux architecture has no pinned Python' 'Use a supported x86_64 Linux host'
if ! command -v tar >/dev/null 2>&1 || ! command -v gzip >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1 || ! command -v realpath >/dev/null 2>&1 || ! command -v find >/dev/null 2>&1; then
  fail bootstrap_prerequisite_unavailable 'tar, gzip, sha256sum, realpath or find is unavailable' 'Install standard Linux archive and checksum tools'
fi
if [ -z "$custom_archive" ]; then
  if command -v curl >/dev/null 2>&1; then downloader=curl
  elif command -v wget >/dev/null 2>&1; then
    wget_version=$(wget --no-config --version 2>/dev/null) || fail download_prerequisite_unavailable 'curl or GNU Wget 1.x is required' 'Install curl or GNU Wget 1.x'
    case $wget_version in
      'GNU Wget 1.'[0-9]*) downloader=wget ;;
      *) fail download_prerequisite_unavailable 'curl or GNU Wget 1.x is required' 'Install curl or GNU Wget 1.x' ;;
    esac
  else fail download_prerequisite_unavailable 'curl or GNU Wget 1.x is required' 'Install curl or GNU Wget 1.x'
  fi
fi
if ! safe_dir "$root/tmp" || ! safe_dir "$root/tmp/$op" || ! safe_dir "$root/runtimes" || ! safe_dir "$root/runtimes/python"; then
  fail root_unavailable 'Runtime directories are unavailable' 'Check root permissions and links'
fi
if ! private_path "$root/tmp/$op" || ! private_path "$root/runtimes/python"; then
  fail root_not_private 'Bootstrap directories are not private' 'Choose a user-owned root without shared writes'
fi
stage=$root/tmp/$op/bootstrap
mkdir -m 700 "$stage" || fail staging_unavailable 'Bootstrap staging is unavailable' 'Check root permissions'
printf 'stemwerk-bootstrap-owner/1\t%s\t%s\n' "$op" "$$" > "$stage/owner"
event active_indeterminate '"since_seconds":0'

cancel_check() {
  [ ! -e "$opdir/cancel.request" ] || fail cancelled 'Bootstrap cancellation was requested' 'Start a new operation'
}
wait_active() {
  last_report=$(date +%s)
  while kill -0 "$dlpid" 2>/dev/null; do
    sleep 0.25
    cancel_check
    now=$(date +%s)
    if [ $((now - last_report)) -ge 3 ]; then
      event active_indeterminate '"since_seconds":0'
      last_report=$now
    fi
  done
  wait "$dlpid"
  status_code=$?
  dlpid=
  return "$status_code"
}
cancel_check
archive=$stage/python.tar.gz
headers=$stage/headers
redirects=0
if [ -n "$custom_archive" ]; then
  [ -f "$custom_archive" ] && [ ! -L "$custom_archive" ] || fail archive_unavailable 'Archive file is unavailable' 'Provide a readable regular archive file'
  cp -- "$custom_archive" "$archive" || fail archive_unavailable 'Archive file could not be staged' 'Check archive file permissions and free space'
else
while :; do
  case $url in
    https://github.com/*|https://release-assets.githubusercontent.com/*|https://objects.githubusercontent.com/*) ;;
    *) fail network_policy_refused 'Download host or scheme is not approved' 'Restore the shipped manifest' ;;
  esac
  case $url in *'#'*) fail network_policy_refused 'URL fragment is not approved' 'Restore the shipped manifest' ;; esac
  if [ "$downloader" = curl ]; then
    (
      unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY ftp_proxy FTP_PROXY no_proxy NO_PROXY
      exec curl -q --noproxy '*' --silent --show-error --proto '=https' --max-time 300 --max-redirs 0 -H 'Accept: */*' -H 'Accept-Encoding: identity' -H 'Connection: close' -A 'STEMwerk-bootstrap/1' -D "$headers" -o "$archive" -w '%{http_code}' "$url"
    ) > "$stage/httpstatus" 2> "$stage/download.err" &
  else
    (
      unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY ftp_proxy FTP_PROXY no_proxy NO_PROXY
      # GNU Wget answers SIGHUP by moving its log to wget-log in the working
      # directory and continuing. The parent's HUP handling stops it with TERM.
      trap '' HUP
      exec wget --no-config --no-netrc --no-hsts --no-proxy --https-only --max-redirect=0 --timeout=300 --header='Accept-Encoding: identity' --user-agent='STEMwerk-bootstrap/1' -S -O "$archive" "$url"
    ) > /dev/null 2> "$headers" &
  fi
  dlpid=$!
  if ! wait_active; then
    [ "$downloader" = wget ] || fail direct_https_failed 'Direct HTTPS archive download failed' 'Check direct HTTPS access and retry'
  fi
  if [ "$downloader" = curl ]; then
    status=$(cat "$stage/httpstatus")
  else
    status=$(sed -n 's/^  HTTP\/[^ ]* \([0-9][0-9][0-9]\).*/\1/p' "$headers" | tail -n 1)
  fi
  case $status in
    200) break ;;
    301|302|303|307|308)
      [ "$redirects" -lt 5 ] || fail network_policy_refused 'Too many archive redirects' 'Check the vendor release URL'
      if [ "$downloader" = wget ]; then
        next=$(sed -n 's/^  [Ll]ocation: //p' "$headers" | tail -n 1 | tr -d '\r')
      else
        next=$(sed -n 's/^[Ll]ocation: //p' "$headers" | tail -n 1 | tr -d '\r')
      fi
      [ -n "$next" ] || fail network_policy_refused 'Redirect has no location' 'Check the vendor release URL'
      url=$next
      redirects=$((redirects + 1)) ;;
    *) fail direct_https_failed 'Direct HTTPS archive request returned an error' 'Check direct HTTPS access and retry' ;;
  esac
  cancel_check
done
fi
cancel_check
actual_size=$(wc -c < "$archive" | tr -d '[:space:]')
[ "$actual_size" = "$size" ] || fail archive_size_mismatch 'Archive byte count differs from pin' 'Retry the download'
sha256sum "$archive" > "$stage/digest" &
dlpid=$!
wait_active || fail archive_unavailable 'Archive could not be hashed' 'Check the downloaded file'
actual_sha=$(cut -d ' ' -f 1 < "$stage/digest")
[ "$actual_sha" = "$sha" ] || fail archive_sha256_mismatch 'Archive SHA-256 differs from pin' 'Restore the pinned manifest or retry'
event active_indeterminate '"since_seconds":0'

# Preflight names and types before extraction. GNU tar rejects link traversal
# during extraction as an additional barrier; the verified pin is the trust root.
tar -tzf "$archive" > "$stage/members" &
dlpid=$!
wait_active || fail archive_unsafe 'Archive listing failed' 'Restore the pinned archive'
while IFS= read -r member; do
  case $member in python|python/*) ;; *) fail archive_unsafe 'Archive has a path outside python' 'Restore the pinned archive' ;; esac
  case /$member/ in */../*|*/./*|*'//'*) fail archive_unsafe 'Archive has a traversal path' 'Restore the pinned archive' ;; esac
done < "$stage/members"
tar -tvzf "$archive" > "$stage/types" &
dlpid=$!
wait_active || fail archive_unsafe 'Archive type listing failed' 'Restore the pinned archive'
while IFS= read -r entry; do
  kind=${entry%"${entry#?}"}
  case $kind in -|d|l) ;; *) fail archive_unsafe 'Archive contains an unsafe entry type' 'Restore the pinned archive' ;; esac
  if [ "$kind" = l ]; then
    case $entry in *' -> '*) target=${entry##*' -> '} ;; *) fail archive_unsafe 'Archive symlink is malformed' 'Restore the pinned archive' ;; esac
    case $target in /*) fail archive_unsafe 'Archive symlink is absolute' 'Restore the pinned archive' ;; esac
    linkpath=${entry%' -> '*}
    linkpath=${linkpath##* }
    resolved=$(realpath -m "$stage/${linkpath%/*}/$target") || fail archive_unsafe 'Archive symlink could not be resolved' 'Restore the pinned archive'
    case $resolved in "$stage/python"/*) ;; *) fail archive_unsafe 'Archive symlink escapes Python staging' 'Restore the pinned archive' ;; esac
  fi
done < "$stage/types"
tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$stage" || fail unpack_failed 'Pinned archive could not be unpacked' 'Check free space and retry'
[ -d "$stage/python" ] && [ ! -L "$stage/python" ] || fail unpack_failed 'Archive has no Python directory' 'Restore the pinned archive'
find "$stage/python" -type l -print > "$stage/links" &
dlpid=$!
wait_active || fail archive_unsafe 'Extracted-link inspection failed' 'Check the find utility and retry'
while IFS= read -r link; do
  resolved=$(realpath -m "$link") || fail archive_unsafe 'Extracted link could not be resolved' 'Restore the pinned archive'
  case $resolved in "$stage/python"/*) ;; *) fail archive_unsafe 'Archive link escapes Python staging' 'Restore the pinned archive' ;; esac
done < "$stage/links"
cancel_check
"$stage/python/bin/python3.12" -I -B "$src/linux_bootstrap_publish.py" "$root" "$stage/python" "$name" > "$stage/outcome" &
dlpid=$!
if ! wait_active; then
  outcome=$(cat "$stage/outcome")
  fail "${outcome:-publication_failed}" 'Managed Python publication failed' 'Inspect the runtime destination and retry'
fi
outcome=$(cat "$stage/outcome")
case $outcome in new|reused) ;; *) fail publication_failed 'Publisher returned an invalid result' 'Inspect the runtime destination' ;; esac
printf '%s\n' "$outcome" > "$opdir/bootstrap.outcome" || fail operation_log_unavailable 'Cannot record publication outcome' 'Check operation log permissions'
rm -rf -- "$stage" || fail staging_cleanup_failed 'Published runtime but staging cleanup failed' 'Inspect operation staging'
stage=
event 'done' '"verified":true'
STEMWERK_RUNTIME_ROOT=$root
STEMWERK_OPERATION_ID=$op
PYTHONDONTWRITEBYTECODE=1
export STEMWERK_RUNTIME_ROOT STEMWERK_OPERATION_ID PYTHONDONTWRITEBYTECODE
exec "$root/runtimes/python/$name/bin/python3.12" -I -B "$src" "$@"
