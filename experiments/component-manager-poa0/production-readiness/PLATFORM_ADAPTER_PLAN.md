# Platform adapter plan

PLATFORM_ADAPTER_COUNT=3

GO_BUILD_TAG_PLAN=common contract in internal/platform; files in internal/platform/linux use //go:build linux, windows use //go:build windows, darwin use //go:build darwin; a common unsupported file for !linux && !windows && !darwin returns ErrUnsupportedPlatform and exposes no mutating capability

COMMON_PLATFORM_INTERFACE=Filesystem metadata/no-follow open/atomic publish/file flush/parent sync/permission set plus ProcessProbe.StartIdentity and HelperIdentity verification; paths are confined typed values

LINUX_ADAPTER_PACKAGE=internal/platform/linux

WINDOWS_ADAPTER_PACKAGE=internal/platform/windows

MACOS_ADAPTER_PACKAGE=internal/platform/darwin

UNSUPPORTED_PLATFORM_BEHAVIOR=FAIL_CLOSED

PLATFORM_PLAN_STATUS=RESOLVED

## Required behavior by adapter

| Platform | Required primitives and validation |
|---|---|
| Linux | write+fsync temporary file, rename/replace, fsync parent directory; no-follow metadata; uid/gid/mode checks; PID plus /proc-compatible start identity with unknown blocked. |
| Windows | write and FlushFileBuffers; documented replacement primitive; write-capable parent directory handle and directory FlushFileBuffers proof; volume identity; process creation time; reparse-point rejection; explicit ACL/elevation boundary. |
| macOS | write+fsync, atomic replace and parent-directory durability proof; no-follow metadata/ownership; statfs architecture-safe binding; PID start identity; helper/code-sign identity boundary. |

No native calls are implemented in this gate. Each adapter must pass the shared contract suite before native tests. Unsupported or unverified durability, process identity, link metadata or privilege identity disables the corresponding mutation; it never silently falls back.
