#!/bin/sh
# Linux-only outer bootstrap. Called by STEMwerk_Bootstrap_Linux.sh.
set -uf
umask 022
LC_ALL=C
export LC_ALL

# --- writer group worker (S8 fix3, owner-approved option B) -----------------------------
# Every process that can independently write the bootstrap staging (copy, curl or
# wget, sha256sum, tar, find and the publication helper) runs under ONE dedicated
# process group: this same script, started by the controller with setsid in worker
# mode. The controller stays outside that group, so it can stop the group without
# signalling itself. The group starts with only the read end of a FIFO as stdin and
# its first action is to wait for one complete line "go <pgid>": EOF (the controller
# died or gave up), an incomplete line or anything else ends the worker before it
# has written a byte. After go it serves the controller's step requests one at a
# time, and ends on its own when the controller is gone.
worker_main() {
  IFS= read -r gate_msg || exit 3
  exec </dev/null
  case $gate_msg in
    'go '*) gate_pgid=${gate_msg#go } ;;
    *) exit 3 ;;
  esac
  case $gate_pgid in ''|*[!0-9]*) exit 3 ;; esac
  IFS= read -r self_stat < "/proc/$$/stat" || exit 3
  self_rest=${self_stat##*) }
  set -- $self_rest
  # field 3 of the remainder is this process's group: it must be the published one
  [ "${3:-}" = "$gate_pgid" ] || exit 3
  req=$W_STAGE/step.req
  while :; do
    kill -0 "$W_CONTROLLER" 2>/dev/null || exit 0
    if [ -f "$req" ] && [ ! -L "$req" ]; then
      step_seq=
      step_name=
      step_arg=
      { IFS= read -r step_seq; IFS= read -r step_name; IFS= read -r step_arg; } < "$req"
      rm -f "$req"
      step_rc=0
      case $step_name in
        copy) cp -- "$W_CUSTOM" "$W_ARCHIVE" || step_rc=$? ;;
        curl)
          (
            unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY ftp_proxy FTP_PROXY no_proxy NO_PROXY
            exec curl -q --noproxy '*' --silent --show-error --proto '=https' --max-time 300 --max-redirs 0 -H 'Accept: */*' -H 'Accept-Encoding: identity' -H 'Connection: close' -A 'STEMwerk-bootstrap/1' -D "$W_STAGE/headers" -o "$W_ARCHIVE" -w '%{http_code}' "$step_arg"
          ) > "$W_STAGE/httpstatus" 2> "$W_STAGE/download.err" || step_rc=$? ;;
        wget)
          (
            unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY ftp_proxy FTP_PROXY no_proxy NO_PROXY
            # GNU Wget answers SIGHUP by moving its log to wget-log in the working
            # directory and continuing. The controller stops the group with TERM.
            trap '' HUP
            exec wget --no-config --no-netrc --no-hsts --no-proxy --https-only --max-redirect=0 --timeout=300 --header='Accept-Encoding: identity' --user-agent='STEMwerk-bootstrap/1' -S -O "$W_ARCHIVE" "$step_arg"
          ) > /dev/null 2> "$W_STAGE/headers" || step_rc=$? ;;
        digest) sha256sum "$W_ARCHIVE" > "$W_STAGE/digest" || step_rc=$? ;;
        list) tar -tzf "$W_ARCHIVE" > "$W_STAGE/members" || step_rc=$? ;;
        types) tar -tvzf "$W_ARCHIVE" > "$W_STAGE/types" || step_rc=$? ;;
        extract) tar --no-same-owner --no-same-permissions -xzf "$W_ARCHIVE" -C "$W_STAGE" || step_rc=$? ;;
        links) find "$W_STAGE/python" -type l -print > "$W_STAGE/links" || step_rc=$? ;;
        publish) "$W_STAGE/python/bin/python3.12" -I -B "$W_SRC/linux_bootstrap_publish.py" "$W_ROOT" "$W_STAGE/python" "$W_NAME" > "$W_STAGE/outcome" || step_rc=$? ;;
        *) step_rc=127 ;;
      esac
      printf '%s %s\n' "$step_seq" "$step_rc" > "$W_STAGE/step.done.tmp"
      ln "$W_STAGE/step.done.tmp" "$W_STAGE/step.done" || :
      rm -f "$W_STAGE/step.done.tmp"
      continue
    fi
    sleep 0.05
  done
}
if [ "${1:-}" = --stemwerk-bootstrap-worker ]; then
  worker_main
  exit 0
fi
self_script=$0

reaper=$1
shift
root=
custom_archive=
op_id_arg=
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
    --operation-id)
      op_id_arg=$2
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
  printf '%s\n' 'usage: --managed-python-bootstrap --root ABSOLUTE_ROOT [--archive ARCHIVE_PATH] [--operation-id UUID] -- CORE_ARGUMENTS' >&2
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
wpid=
wpgid=
my_pgid=
group_unsure=
step_seq=0
check_errno=
check_message=

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

# --- the controller side of the writer group (see worker_main) --------------------------
# proc_state PID sets pstate (R, S, Z, ...), pgrp_of and sid_of from /proc/PID/stat; it
# fails when the process does not exist. A zombie counts as dead.
proc_state() {
  pstate=
  pgrp_of=
  sid_of=
  _stat_line=
  { IFS= read -r _stat_line < "/proc/$1/stat"; } 2>/dev/null || return 1
  _stat_rest=${_stat_line##*) }
  set -- $_stat_rest
  pstate=${1:-}
  pgrp_of=${3:-}
  sid_of=${4:-}
  [ -n "$pgrp_of" ]
}
proc_alive() {
  proc_state "$1" && [ "$pstate" != Z ] && [ "$pstate" != X ]
}
reap_worker() {
  if [ -n "$wpid" ] && proc_state "$wpid" && [ "$pstate" = Z ]; then
    wait "$wpid" 2>/dev/null || :
  fi
}
# group_alive: 0 while the recorded group may still have members (an unanswerable or
# EPERM probe counts as alive), 1 only when the probe answers "No such process" (ESRCH).
# S8 fix4: the POSIX form "kill -s 0 -- -PGID"; dash rejects "kill -0 -- -PGID" with
# "Illegal number", which is never ESRCH, so under dash the group could never be shown
# empty. The probe runs in the controller, whose /proc view start_group established, on
# the group id it recorded: observer and recorder are the same, on the same boot.
group_alive() {
  _probe=$(kill -s 0 -- "-$wpgid" 2>&1)
  _probe_rc=$?
  [ "$_probe_rc" -ne 0 ] || return 0
  case $_probe in
    *'No such process'*) return 1 ;;
  esac
  return 0
}
# stop_group: TERM the whole group, at most 5 s grace, then KILL, at most 5 s more; the
# leader is reaped; every wait is bounded. Fails (and sets group_unsure) when emptiness
# could not be shown, which keeps the staging. Never signals the controller's own group.
stop_group() {
  [ -n "$wpgid" ] || return 0
  if [ "$wpgid" = "$my_pgid" ]; then
    group_unsure=1
    return 1
  fi
  kill -s TERM -- "-$wpgid" 2>/dev/null || :
  _tries=0
  while group_alive; do
    reap_worker
    _tries=$((_tries + 1))
    [ "$_tries" -lt 100 ] || break
    sleep 0.05
  done
  if group_alive; then
    kill -s KILL -- "-$wpgid" 2>/dev/null || :
    _tries=0
    while group_alive; do
      reap_worker
      _tries=$((_tries + 1))
      [ "$_tries" -lt 100 ] || break
      sleep 0.05
    done
  fi
  reap_worker
  if group_alive; then
    group_unsure=1
    return 1
  fi
  # Shown empty: forget the group, so a later stop can never signal a recycled id.
  wpgid=
  wpid=
  return 0
}
# abort_gate: the release did not happen. Closing the controller's end of the FIFO is
# the EOF that ends the waiting group; it is stopped for certain anyway.
abort_gate() {
  exec 3>&-
  stop_group || :
  fail "$1" "$2" "$3"
}

# start_group: create the worker group behind the pipe gate and release it only after
# its record is durable.
#  1. a FIFO in the staging; the controller opens it read-write (it never blocks) and
#     is the only holder of the write side, so the group sees EOF if the controller
#     dies. Every child started while it is open closes it (3>&-).
#  2. the group is started with ONLY the read end as stdin (setsid: its own session
#     and group) and nothing else; its first action is to wait for "go <pgid>".
#  3. the real group id is read from /proc (never assumed from the launcher's pid) and
#     must differ from the controller's own group.
#  4. bootstrap/group (staging path, pgid, boot id, PID namespace) is written, synced,
#     published without replacing and synced again; only then is "go" sent.
#     Any failure closes the pipe without release.
# S8 fix4: the group id is a NUMBER in one PID namespace, and it is read from /proc.
# Before anything is started, /proc must be shown to number this controller's own PID
# namespace: the NSpid line of /proc/self/status, opened by this shell itself, has
# exactly one entry and it is $$ (more entries mean /proc belongs to an outer
# namespace). Only then are the group id read from /proc/<pid>/stat, the controller's own
# kill -0 checks (stop_group) and the namespace read via readlink /proc/self/ns/pid the
# same viewpoint, and the recorded namespace is the one in which the number means this
# group. If it cannot be shown, nothing is started.
start_group() {
  proc_view=
  { while IFS= read -r _status_line; do
      case $_status_line in NSpid:*) proc_view=${_status_line#NSpid:} ;; esac
    done < /proc/self/status; } 2>/dev/null || proc_view=
  set -- $proc_view
  { [ "$#" = 1 ] && [ "$1" = "$$" ]; } \
    || fail bootstrap_prerequisite_unavailable '/proc does not number the PID namespace of the bootstrap' 'Run the bootstrap where /proc is mounted for its own PID namespace'
  proc_state "$$" || fail bootstrap_prerequisite_unavailable 'Cannot read /proc for the bootstrap process group' 'Check Linux proc access'
  my_pgid=$pgrp_of
  fifo=$stage/gate
  mkfifo -m 600 "$fifo" 3>&- || fail staging_unavailable 'Bootstrap gate is unavailable' 'Check root permissions'
  ( : 3<>"$fifo" ) 2>/dev/null || fail staging_unavailable 'Bootstrap gate is unavailable' 'Check root permissions'
  exec 3<>"$fifo"
  W_STAGE=$stage W_ARCHIVE=$archive W_CUSTOM=$custom_archive W_SRC=$src W_ROOT=$root W_NAME=$name W_CONTROLLER=$$ \
    setsid /bin/sh "$self_script" --stemwerk-bootstrap-worker < "$fifo" 3>&- &
  wpid=$!
  _tries=0
  wpgid=
  while :; do
    if proc_state "$wpid" && [ "$pstate" != Z ] && [ "$pgrp_of" != "$my_pgid" ] && [ "$pgrp_of" = "$sid_of" ]; then
      wpgid=$pgrp_of
      break
    fi
    proc_alive "$wpid" || abort_gate bootstrap_prerequisite_unavailable 'The bootstrap writer group could not be started' 'Install util-linux (setsid)'
    _tries=$((_tries + 1))
    [ "$_tries" -lt 100 ] || abort_gate bootstrap_prerequisite_unavailable 'The bootstrap writer group did not form' 'Retry the operation'
    sleep 0.05 3>&-
  done
  case $wpgid in ''|*[!0-9]*) abort_gate bootstrap_prerequisite_unavailable 'The bootstrap writer group id is unusable' 'Retry the operation' ;; esac
  { [ "$wpgid" -gt 1 ] && [ "$wpgid" != "$my_pgid" ]; } || abort_gate bootstrap_prerequisite_unavailable 'The bootstrap writer group id is unusable' 'Retry the operation'
  boot_id=
  { IFS= read -r boot_id < /proc/sys/kernel/random/boot_id; } 2>/dev/null || :
  [ -n "$boot_id" ] || abort_gate bootstrap_prerequisite_unavailable 'The Linux boot id is unavailable' 'Check Linux proc access'
  # Recorded only in its exact form pid:[<inode>]; anything else is left empty, which Core
  # treats as no proof (the staging is then kept after a crash, never removed early).
  pid_ns=
  if command -v readlink >/dev/null 2>&1; then pid_ns=$(readlink /proc/self/ns/pid 2>/dev/null 3>&-) || pid_ns=; fi
  _ns_inode=
  case $pid_ns in 'pid:['*']') _ns_inode=${pid_ns#'pid:['}; _ns_inode=${_ns_inode%']'} ;; esac
  case $_ns_inode in ''|0*|*[!0-9]*) pid_ns= ;; esac
  printf 'stemwerk-bootstrap-group/1\t%s\t%s\t%s\t%s\t%s\n' "$op" "$stage" "$wpgid" "$boot_id" "$pid_ns" > "$stage/group.tmp" \
    || abort_gate staging_unavailable 'The bootstrap writer record could not be written' 'Check root permissions'
  sync 3>&- || abort_gate staging_unavailable 'The bootstrap writer record could not be made durable' 'Check the file system'
  ln "$stage/group.tmp" "$stage/group" 3>&- || abort_gate staging_unavailable 'The bootstrap writer record could not be published' 'Check root permissions'
  sync 3>&- || abort_gate staging_unavailable 'The bootstrap writer record could not be made durable' 'Check the file system'
  rm -f "$stage/group.tmp" 3>&-
  printf 'go %s\n' "$wpgid" >&3 || abort_gate staging_unavailable 'The bootstrap writer group could not be released' 'Retry the operation'
  exec 3>&-
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
  stop_group || :
  # When the writer group could not be shown empty the staging stays, and both
  # documents say so (an ordinary failure document carries no "remains").
  fail_extra=
  if [ -n "$group_unsure" ] && [ -n "$stage" ]; then
    fail_extra=",\"remains\":{\"staging_state\":\"retained\",\"retained\":[\"tmp/$op/bootstrap (writer group not proven gone)\"],\"uncertainty\":\"a bootstrap writer process group may still be alive\"}"
  fi
  if [ -n "$opdir" ]; then
    event failed "\"error_code\":\"$code\",\"detail\":\"$detail\",\"action\":\"$action\""
    printf '{"protocol":"stemwerk-install-result/1","operation_id":"%s","exit_code":2,"stream":"stderr","document":{"kind":"stemwerk_module_install_error","schema_version":"1.0.0","error":{"code":"%s","message":"%s","module":null%s}}}\n' \
      "$op" "$code" "$detail" "$fail_extra" > "$opdir/.result.tmp"
    ln "$opdir/.result.tmp" "$opdir/result.json" || :
    rm -f "$opdir/.result.tmp"
  fi
  if [ -n "$stage" ] && [ -d "$stage" ] && [ ! -L "$stage" ] && [ -z "$group_unsure" ]; then
    rm -rf -- "$stage"
  fi
  printf '{"kind":"stemwerk_module_install_error","schema_version":"1.0.0","error":{"code":"%s","message":"%s","module":null%s}}\n' "$code" "$detail" "$fail_extra" >&2
  exit 2
}

# S8 (G1): the operation directory <root>/logs/<op> is the outer layer's own:
# it created it exclusively with mode 700 and writes its events and result
# there. If that directory has since become unsearchable or unwritable (the
# marker lookup failed, or a write would), the terminal pair is still owed,
# so the owner restores mode 700 on that one directory and nothing else. Only
# a real directory (never a link) owned by this user qualifies; if the
# restore is impossible (an ancestor is denied, chmod is not on PATH, another
# owner) the terminal files cannot be written and the stderr document is the
# only carrier of the outcome (exit 2, terminal_record "unwritable").
opdir_restored=
restore_opdir() {
  [ -n "$opdir" ] || return 1
  if [ -d "$opdir" ] && [ ! -L "$opdir" ] && [ -w "$opdir" ] && [ -x "$opdir" ]; then
    return 0
  fi
  [ -d "$opdir" ] && [ ! -L "$opdir" ] || return 1
  command -v chmod >/dev/null 2>&1 || return 1
  opdir_owner=$(stat -c %u -- "$opdir" 2>/dev/null) || return 1
  [ "$opdir_owner" = "$my_uid" ] || return 1
  chmod 700 -- "$opdir" 2>/dev/null || return 1
  [ -w "$opdir" ] && [ -x "$opdir" ] || return 1
  opdir_restored=1
  return 0
}

# S8 (D6): cancellation is its own terminal outcome, not a failure. Exactly one
# terminal result with error.code "cancelled" (the hardlink rename is
# write-once, so an existing result is preserved); owner decision C
# (2026-11-08): the terminal EVENT is the existing v1 state "failed" with
# error_code "cancelled" so unmodified v1 readers parse the whole stream —
# result.json is the authority for the terminal outcome. Cleanup runs BEFORE
# the result is written, so the result describes what was actually removed,
# retained or could not be inspected (review fix: result after cleanup).
cancel() {
  detail=$1
  action=$2
  # The controller stops the writer group (TERM, at most 5 s grace, then KILL, every
  # wait bounded) and only then touches the staging. If emptiness cannot be shown the
  # staging is retained and the uncertainty is reported (S8 fix3).
  stop_group || :
  # Cleanup first: only this operation's own staging. Failure is detected by
  # re-probing afterwards, so the result below describes what was actually
  # removed, retained or could not be inspected.
  staging_state=removed
  retained=
  uncertainty=
  if [ -n "$stage" ]; then
    if [ -n "$group_unsure" ]; then
      staging_state=retained
      retained="\"tmp/$op/bootstrap (writer group not proven gone)\""
      uncertainty=",\"uncertainty\":\"a bootstrap writer process group may still be alive\""
    else
      if [ -d "$stage" ] && [ ! -L "$stage" ]; then
        rm -rf -- "$stage" 2>/dev/null || :
      fi
      if [ -L "$stage" ] || [ -e "$stage" ]; then
        staging_state=retained
        retained="\"tmp/$op/bootstrap (removal failed)\""
      fi
    fi
  fi
  # The operation staging parent is operation-owned too; rm -d only succeeds
  # when it is empty, so nothing else can be removed by accident. A parent
  # that stays behind with content is named as retained. (rm is a required
  # tool; a separate rmdir binary is not guaranteed on a minimal PATH.)
  rm -d -- "$root/tmp/$op" 2>/dev/null || :
  if [ -d "$root/tmp/$op" ] && [ -z "$retained" ]; then
    staging_state=retained
    retained="\"tmp/$op (not empty after cleanup)\""
  fi
  # Honest reporting: when the staging parent itself cannot be searched, the
  # inspection above answered nothing — say so instead of claiming removal.
  if [ -e "$root/tmp/$op" ] && [ ! -x "$root/tmp/$op" ]; then
    staging_state=unknown
    retained="\"tmp/$op (could not be inspected)\""
  fi
  remains="\"remains\":{\"staging_state\":\"$staging_state\",\"retained\":[$retained]$uncertainty}"
  # The terminal pair is written only into a directory that can take it. A
  # failed marker check rides along as a detail field (the errno name and
  # message of the lookup that failed); both documents stay free of a "cancel"
  # object unless there is something to say, so an ordinary cancel is unchanged.
  if [ -n "$opdir" ] && restore_opdir; then
    cancel_fields=
    if [ -n "$check_errno" ]; then
      cancel_fields="\"cancel_reason\":\"check_failed\",\"cancel_check_error\":\"$check_errno: $check_message\""
    fi
    if [ -n "$opdir_restored" ]; then
      [ -z "$cancel_fields" ] || cancel_fields="$cancel_fields,"
      cancel_fields="$cancel_fields\"operation_directory_mode_restored\":true"
    fi
    cancel_obj=
    [ -z "$cancel_fields" ] || cancel_obj="\"cancel\":{$cancel_fields},"
    event failed "\"error_code\":\"cancelled\",\"detail\":\"$detail\",\"action\":\"$action\""
    printf '{"protocol":"stemwerk-install-result/1","operation_id":"%s","exit_code":2,"stream":"stderr","document":{"kind":"stemwerk_module_install_error","schema_version":"1.0.0","operation":"install","phase":"bootstrap","error":{"code":"cancelled","action":"%s","detail":"%s",%s%s}}}\n' \
      "$op" "$action" "$detail" "$cancel_obj" "$remains" > "$opdir/.result.tmp"
    ln "$opdir/.result.tmp" "$opdir/result.json" || :
    rm -f "$opdir/.result.tmp"
  elif [ -n "$opdir" ]; then
    # Case B: the operation directory cannot take a file and cannot be
    # restored. Nothing durable can be written; the stderr document (exit 2)
    # is the caller's only record and says so.
    cancel_fields=
    if [ -n "$check_errno" ]; then
      cancel_fields="\"cancel_reason\":\"check_failed\",\"cancel_check_error\":\"$check_errno: $check_message\","
    fi
    cancel_obj="\"cancel\":{${cancel_fields}\"terminal_record\":\"unwritable\"},"
  fi
  printf '{"kind":"stemwerk_module_install_error","schema_version":"1.0.0","operation":"install","phase":"bootstrap","error":{"code":"cancelled","action":"%s","detail":"%s",%s%s}}\n' "$action" "$detail" "${cancel_obj:-}" "$remains" >&2
  exit 2
}

# S8 (D6, decision a): the marker counts as present when ANY entry sits at the
# path, probed lstat-only: [ -L ] runs FIRST, so a symlink (dangling or not)
# is answered by lstat alone and never followed; anything [ -e ] still finds
# after a false [ -L ] is not a symlink, so its stat equals an lstat there.
# Only ENOENT means absent: when neither probe finds the entry, the lookup is
# only trustworthy when the operation directory itself is searchable
# ([ -d ] and [ -x ] use the real uid); otherwise the lookup failed (e.g.
# EACCES) and the operation stops conservatively with the failed check
# recorded. The marker is never opened, read or removed.
cancel_check() {
  if [ -L "$opdir/cancel.request" ]; then
    cancel 'Bootstrap cancellation was requested' 'Start a new operation'
  fi
  if [ -e "$opdir/cancel.request" ]; then
    cancel 'Bootstrap cancellation was requested' 'Start a new operation'
  fi
  if [ -d "$opdir" ] && [ -x "$opdir" ]; then
    return 0
  fi
  # The lookup did not answer: stop conservatively (decision a) and record
  # the failed check in the terminal result. Ask the lookup once more, with a
  # tool that reports the errno text (stat is lstat-only without -L): a
  # success means the marker is there after all; otherwise the message names
  # what failed, which the terminal result carries as a detail field.
  if diag=$(stat -c %F -- "$opdir/cancel.request" 2>&1); then
    cancel 'Bootstrap cancellation was requested' 'Start a new operation'
  fi
  check_message=$(printf '%s' "${diag##*: }" | tr -cd 'A-Za-z0-9 ._/-')
  case $check_message in
    'Permission denied') check_errno=EACCES ;;
    'Not a directory') check_errno=ENOTDIR ;;
    'No such file or directory') check_errno=ENOENT ;;
    'Input/output error') check_errno=EIO ;;
    'Too many levels of symbolic links') check_errno=ELOOP ;;
    'File name too long') check_errno=ENAMETOOLONG ;;
    *) check_errno=UNKNOWN ;;
  esac
  [ -n "$check_message" ] || check_message='no diagnostic available'
  cancel 'The cancel marker lookup failed (the operation directory is not searchable); stopped conservatively' 'Check the operation directory permissions and start a new operation'
}
# run_step NAME [ARG]: ask the worker group to run one step and wait for its status.
# The request and the status travel as small files in the staging (the controller's own
# writes); the wait polls the cancel marker every 0.1 s and heartbeats every 3 s.
run_step() {
  step_seq=$((step_seq + 1))
  rm -f "$stage/step.done" "$stage/step.req.tmp"
  printf '%s\n%s\n%s\n' "$step_seq" "$1" "${2:-}" > "$stage/step.req.tmp" || fail staging_unavailable 'Bootstrap staging is unavailable' 'Check root permissions'
  ln "$stage/step.req.tmp" "$stage/step.req" || fail staging_unavailable 'Bootstrap staging is unavailable' 'Check root permissions'
  rm -f "$stage/step.req.tmp"
  wait_step
}
wait_step() {
  last_report=$(date +%s)
  while [ ! -f "$stage/step.done" ]; do
    proc_alive "$wpid" || { [ -f "$stage/step.done" ] && break; return 125; }
    sleep 0.1
    cancel_check
    now=$(date +%s)
    if [ $((now - last_report)) -ge 3 ]; then
      event active_indeterminate '"since_seconds":0'
      last_report=$now
    fi
  done
  step_done_seq=
  step_done_rc=125
  read -r step_done_seq step_done_rc < "$stage/step.done" || :
  rm -f "$stage/step.done"
  [ "$step_done_seq" = "$step_seq" ] || return 125
  return "$step_done_rc"
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
if ! command -v setsid >/dev/null 2>&1 || ! command -v mkfifo >/dev/null 2>&1 || ! command -v sync >/dev/null 2>&1; then
  fail bootstrap_prerequisite_unavailable 'setsid, mkfifo or sync is unavailable' 'Install util-linux (setsid) and coreutils (mkfifo, sync)'
fi
my_uid=$(id -u) || fail bootstrap_prerequisite_unavailable 'Cannot determine current user' 'Check account tools'
safe_dir "$root" || fail root_unavailable 'Root path is unavailable or contains a link' 'Choose a private root without links'
private_path "$root" || fail root_not_private 'Root or ancestor is not private to this user' 'Choose a user-owned root without shared writes'
safe_dir "$root/logs" || fail operation_log_unavailable 'Cannot create operation logs directory' 'Check root permissions'
private_path "$root/logs" || fail root_not_private 'Operation logs directory is not private' 'Choose a user-owned root without shared writes'
if [ -n "$op_id_arg" ]; then
  # The front end chooses the operation id (design 7.2); only the lowercase
  # canonical form Core validates (install_events._check_operation_id) is accepted.
  case $op_id_arg in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) fail operation_id_invalid 'Operation id is not a lowercase canonical UUID' 'Pass a canonical UUID as the operation id' ;;
  esac
  op=$op_id_arg
else
  op=$(cat /proc/sys/kernel/random/uuid) || fail operation_id_unavailable 'Cannot create operation identifier' 'Check Linux proc access'
fi
candidate_opdir=$root/logs/$op
mkdir -m 700 "$candidate_opdir" || fail operation_log_unavailable 'Cannot create operation log' 'Check root permissions'
opdir=$candidate_opdir
started_at=$(date +%s)
event active_indeterminate '"since_seconds":0'
trap 'cancel "Bootstrap was interrupted" "Start a new operation"' HUP INT TERM
# Bootstrap entry safe point: a marker placed before startup is honoured here,
# before any download or extraction begins.
cancel_check

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
# Owner protocol /2: this outer layer releases a writer only after it published
# bootstrap/group (see start_group), so "/2 and no group record" means no writer
# ever ran. A /1 record is the legacy PID-only evidence.
printf 'stemwerk-bootstrap-owner/2\t%s\t%s\n' "$op" "$$" > "$stage/owner"
event active_indeterminate '"since_seconds":0'

archive=$stage/python.tar.gz
headers=$stage/headers
redirects=0
start_group
cancel_check
if [ -n "$custom_archive" ]; then
  [ -f "$custom_archive" ] && [ ! -L "$custom_archive" ] || fail archive_unavailable 'Archive file is unavailable' 'Provide a readable regular archive file'
  run_step copy || fail archive_unavailable 'Archive file could not be staged' 'Check archive file permissions and free space'
else
while :; do
  case $url in
    https://github.com/*|https://release-assets.githubusercontent.com/*|https://objects.githubusercontent.com/*) ;;
    *) fail network_policy_refused 'Download host or scheme is not approved' 'Restore the shipped manifest' ;;
  esac
  case $url in *'#'*) fail network_policy_refused 'URL fragment is not approved' 'Restore the shipped manifest' ;; esac
  if ! run_step "$downloader" "$url"; then
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
run_step digest || fail archive_unavailable 'Archive could not be hashed' 'Check the downloaded file'
actual_sha=$(cut -d ' ' -f 1 < "$stage/digest")
[ "$actual_sha" = "$sha" ] || fail archive_sha256_mismatch 'Archive SHA-256 differs from pin' 'Restore the pinned manifest or retry'
event active_indeterminate '"since_seconds":0'

# Preflight names and types before extraction. GNU tar rejects link traversal
# during extraction as an additional barrier; the verified pin is the trust root.
run_step list || fail archive_unsafe 'Archive listing failed' 'Restore the pinned archive'
while IFS= read -r member; do
  case $member in python|python/*) ;; *) fail archive_unsafe 'Archive has a path outside python' 'Restore the pinned archive' ;; esac
  case /$member/ in */../*|*/./*|*'//'*) fail archive_unsafe 'Archive has a traversal path' 'Restore the pinned archive' ;; esac
done < "$stage/members"
run_step types || fail archive_unsafe 'Archive type listing failed' 'Restore the pinned archive'
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
run_step extract || fail unpack_failed 'Pinned archive could not be unpacked' 'Check free space and retry'
[ -d "$stage/python" ] && [ ! -L "$stage/python" ] || fail unpack_failed 'Archive has no Python directory' 'Restore the pinned archive'
run_step links || fail archive_unsafe 'Extracted-link inspection failed' 'Check the find utility and retry'
while IFS= read -r link; do
  resolved=$(realpath -m "$link") || fail archive_unsafe 'Extracted link could not be resolved' 'Restore the pinned archive'
  case $resolved in "$stage/python"/*) ;; *) fail archive_unsafe 'Archive link escapes Python staging' 'Restore the pinned archive' ;; esac
done < "$stage/links"
cancel_check
if ! run_step publish; then
  outcome=$(cat "$stage/outcome")
  fail "${outcome:-publication_failed}" 'Managed Python publication failed' 'Inspect the runtime destination and retry'
fi
outcome=$(cat "$stage/outcome")
case $outcome in new|reused) ;; *) fail publication_failed 'Publisher returned an invalid result' 'Inspect the runtime destination' ;; esac
printf '%s\n' "$outcome" > "$opdir/bootstrap.outcome" || fail operation_log_unavailable 'Cannot record publication outcome' 'Check operation log permissions'
# The worker group is stopped (bounded) and shown empty BEFORE the staging is removed.
stop_group || fail staging_cleanup_failed 'Published runtime but the bootstrap writer group is not proven gone' 'Inspect operation staging'
rm -rf -- "$stage" || fail staging_cleanup_failed 'Published runtime but staging cleanup failed' 'Inspect operation staging'
stage=
wpid=
wpgid=
event 'done' '"verified":true'
STEMWERK_RUNTIME_ROOT=$root
STEMWERK_OPERATION_ID=$op
PYTHONDONTWRITEBYTECODE=1
export STEMWERK_RUNTIME_ROOT STEMWERK_OPERATION_ID PYTHONDONTWRITEBYTECODE
unset W_STAGE W_ARCHIVE W_CUSTOM W_SRC W_ROOT W_NAME W_CONTROLLER
exec "$root/runtimes/python/$name/bin/python3.12" -I -B "$src" "$@"
