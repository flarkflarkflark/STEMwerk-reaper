# Core install lock and operation journal

One mutating installation operation runs per user at a time
([design](Core_Module_Installation_Design.md), section 8, decision D8). This
page describes the libraries that enforce it: `stemwerk_core.install_lock`,
`stemwerk_core.install_journal` and `stemwerk_core.process_identity`. No
command takes the lock yet; the first operation that does is the install
(slice S6). `verify` reads the lock (see
[Core module verification](Core_Module_Verification.md)).

`<root>` is `managed_runtime_root()`: `%LOCALAPPDATA%\STEMwerk`,
`~/Library/Application Support/STEMwerk` or `$XDG_DATA_HOME/STEMwerk`
(`~/.local/share/STEMwerk`), overridable with `STEMWERK_RUNTIME_ROOT`.

## Files

| Path under `<root>/state/locks/` | Written by | Content |
| --- | --- | --- |
| `install.lock` | the holder, once, created exclusively | `protocol` (`stemwerk-install-lock/1`), `operation_id`, `pid`, `start_token`, `host`, `created` |
| `install.heartbeat` | the holder, every interval (default 5 s), with `os.replace` | `protocol` (`stemwerk-install-heartbeat/1`), `operation_id`, `pid`, `ts` |
| `install.guard` | created once, never removed | empty |
| `broken/<name>.lock` and `broken/<name>.lock.break.json` | the operation that broke a stale lock | the moved lock and the break record |

Each file is one JSON object in UTF-8 followed by `\n`. Timestamps are
RFC 3339 UTC with microseconds.

The holder keeps `install.lock` open and holds an OS lock on it:
`fcntl.flock` on POSIX; on Windows `msvcrt.locking` on one byte at offset
1 GiB, beyond the metadata, because Windows byte-range locks are mandatory
and readers must still read the metadata. The OS releases the lock when the
process dies, also after `SIGKILL` or `TerminateProcess`. If the file system
cannot take an OS lock (some network file systems), acquisition fails with
`lock_unsupported`; there is no fallback.

## Acquiring

`install_lock.acquire(root, operation_id, heartbeat_interval=5.0,
stale_after=30.0, guard_timeout=10.0, verify_published=None)` returns an
`InstallLock`; use it with `with` or call `release()`. Under the OS lock on
`install.guard` it:

1. creates `install.lock` exclusively; if it exists, judges it (below) and
   either fails with `lock_held` or breaks it and tries again;
2. takes the OS lock on the new file and writes the metadata once, then
   fsyncs it;
3. writes the first heartbeat and removes heartbeat temporaries of earlier
   holders.

It then starts the heartbeat thread, leaves the guard, and runs journal
recovery (below); the report is `lock.recovery`, the broken locks are
`lock.broken`. Finally it removes stale bootstrap staging that crashed outer
layers left in `<root>/tmp/<op>/bootstrap/`; the report is
`lock.bootstrap_cleanup` (see
[managed Python bootstrap](Core_Managed_Python_Bootstrap.md)). If recovery or
that cleanup raises, the lock is released first.

`release()` stops the heartbeat and, under the guard, removes the heartbeat
and the lock file (after checking it is still the same file) and closes the
handle. On Windows the handle is closed first, because an open file cannot
be removed there. If the file cannot be removed, the lock stays until the
process exits and then becomes stale after the bound.

Errors are `LockError` with a stable `code`: `lock_held` (`details` has
`lock_status`, `owner` and `conditions`), `lock_unreadable`,
`lock_unsupported`, `lock_guard_timeout`, `lock_break_failed`,
`lock_path_ineligible`, `lock_path_unavailable`, `lock_failed` and
`lock_invalid`.

## When a lock is stale

A lock is stale only if ALL of these hold:

1. its `host` is this computer's host name;
2. nobody holds its OS lock;
3. its PID is not running, or the running process has a different start
   token (the PID was reused);
4. its last heartbeat is older than `stale_after` (default 30 s). The last
   heartbeat is the heartbeat file's `ts` if it belongs to the same
   operation and PID, otherwise the lock's `created`.

Whatever cannot be decided counts as live: a lock from another host is never
broken, and a live PID whose start token cannot be read is treated as the
same process.

**Abandoned during creation** (owner decision 2026-11-01). A creator that
dies between creating `install.lock` and writing its metadata leaves a lock
without valid metadata. Such a lock is stale only if ALL of these hold:

1. its content is empty, truncated (it does not end with the record's `\n`)
   or unparseable (not UTF-8 JSON);
2. nobody holds its OS lock;
3. the file is older than `stale_after` (its modification time).

Rule 2 proves the creator is gone because the creator takes the OS lock right
after the exclusive create and before it writes the metadata (and holds the
guard throughout). A lock with complete, parseable but invalid metadata, or one
that is not a regular file, is still never broken: it is refused with
`lock_unreadable` and left for a person to remove.

Start tokens, standard library only (`process_identity`):

| OS | Running? | Start token |
| --- | --- | --- |
| Linux | `/proc/<pid>/stat` exists and the state is not `Z` or `X` | `linux:<boot_id>:<field 22>` |
| macOS | `os.kill(pid, 0)`; `pbi_status` not zombie | `darwin:<sec>.<usec>` from `proc_pidinfo(PROC_PIDTBSDINFO)` |
| Windows | `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION \| SYNCHRONIZE)` and `WaitForSingleObject(handle, 0)` | `win32:<creation FILETIME>` from `GetProcessTimes` |

`os.kill(pid, 0)` is never called on Windows: CPython maps it to
`TerminateProcess`, which would kill the owner.

## Breaking

Only an acquiring operation breaks a lock, and only under the guard, so two
operations cannot both judge the same lock stale. The lock is moved to
`broken/install.<UTC>.<operation_id>.lock` (`…<UTC>.abandoned.lock` for a lock
abandoned during creation) and a `.break.json` record is written next to it:

```json
{"protocol":"stemwerk-install-lock-break/1","broken_at":"…","lock_file":"install.….lock",
 "reason":"stale_owner","lock":{…the moved metadata…},"heartbeat":{…or null…},
 "conditions":{"same_host":true,"os_lock_free":true,"pid_running":false,
  "start_time_matches":null,"heartbeat_age_seconds":41.2,"stale_after_seconds":30.0},
 "breaker":{"operation_id":"…","pid":…,"start_token":"…","host":"…"}}
```

For a lock abandoned during creation, `reason` is
`abandoned_during_creation`, `lock` and `heartbeat` are `null`, and
`conditions` holds `metadata` (`empty`, `truncated` or `unparseable`),
`os_lock_free`, `lock_age_seconds` and `stale_after_seconds`.

At most 10 broken records are kept; older ones are removed under the guard.

## Reading without taking (`inspect_lock`)

`inspect_lock(root)` returns `lock_status`, `operation_in_progress` and
`operation_id` without creating, changing or locking anything. It cannot
check the OS lock, so it judges staleness from rules 1, 3 and 4 only, and a
lock abandoned during creation from its content and age only; it reports such
a lock as `stale` with `operation_id` `null`.

| `lock_status` | `operation_in_progress` |
| --- | --- |
| `free` | `false` |
| `held` | `true` |
| `stale` | `false` |
| `foreign_host`, `unsupported`, `unreadable` | `null` (cannot be judged) |

## Journal

`install_journal.open_journal(root, operation_id)` creates
`<root>/tmp/<op>/journal.ndjson` and the operation's own staging directory
`<root>/tmp/<op>/core/`. The operation directory may already hold the outer
layer's bootstrap staging (design section 6.1); that content is never
journaled and never touched. Call it only while holding the lock.

The journal is append-only NDJSON, protocol `stemwerk-install-journal/1`,
each record with `operation_id`, `seq` (from 1) and `ts`:

- `open`: first; `operation_directory_created` says whether Core created
  `<root>/tmp/<op>/`;
- `intent`: `action` (`create_directory`, `create_file`, `rename`,
  `remove`), `path` relative to `<root>` and, for a rename, `destination`.
  It is written, flushed and fsynced BEFORE the mutation; if that fails the
  mutation does not start;
- `completion`: `intent_seq` and the `identity` (`device`, `inode`,
  `is_directory`) of what exists afterwards (`null` after a removal).

Every `path` must be inside `core/`; a rename's destination may be anywhere
below `<root>` (a publication). The helpers `create_directory`,
`create_file`, `rename` (native no-replace) and `remove` write both records
around the mutation. A reader ignores an incomplete last line.

## Recovery

After every acquisition, `install_journal.recover(root,
current_operation_id=…, verify_published=…)` processes every
`<root>/tmp/<op>/` that has a journal, except the current operation. Holding
the lock means no other Core operation runs, so these are interrupted
operations. Records are handled newest first:

- a created item is removed only if its identity matches the completion
  record; an item whose mutation never completed is removed only if it is
  inside `core/`; no item is reached through a link or reparse point;
- a rename that completed (or whose destination has the source's identity)
  is a publication: it is verified with `verify_published(destination)` if
  given, and never deleted;
- an item that was replaced or could not be removed is kept, and so is every
  journaled directory that contains it.

`core/` is removed last. When nothing was kept, the journal is removed, and
the operation directory too if Core created it and it is now empty.
Otherwise the journal stays and the next recovery reports the same items.
Directories without a journal (for example the outer layer's bootstrap
staging), entries that are not operation IDs, and everything outside
`<root>/tmp/` are never touched.

## Permissions and links

Directories Core creates get mode 0o700 and files 0o600 (POSIX; set exactly,
whatever the umask). The permissions of `<root>` itself and of directories
and files that already exist, for example from 2.3, are never changed. No
component below `<root>` may be a symbolic link or reparse point
(`lock_path_ineligible`, or `unreadable` in `verify`); `<root>` itself and its
ancestors may be.

## Not in this slice

No command takes the lock (S6). The phase `lock` in the events file, the
`lock_held` result document and the front-end message while a stale lock is
handled come with the operations that use the lock (S6, S9). Bootstrap
staging has no journal; its cleanup (O55) runs after recovery and is
described with the [managed Python bootstrap](Core_Managed_Python_Bootstrap.md).
In-use markers for runtimes and assets are parked (O13).
