# Storage layout contract

Paths are adapter configuration, never contract identities. Every accepted relative path is normalized once, must be UTF-8 representable, must not be absolute, empty, dot/dot-dot, device-named or contain alternate separators/streams, and must remain below its resolved allowlisted root.

## Logical roots

| Root | Purpose and mutability |
|---|---|
| manager | scope container and format marker |
| components | immutable component descriptors |
| artifacts | content-addressed immutable bytes |
| receipts | immutable validated receipts |
| generations | immutable complete manifests/content |
| selectors | tiny durable active selector, separate from SQLite |
| state | desired state and recovery metadata |
| journals | append-only operation/transaction records |
| trust | durable public roots/snapshots and monotone sequence evidence |
| catalogs | validated immutable/cache catalog records |
| diagnostics | redacted events/support bundles |
| temporary | same-filesystem staging only |
| quarantine | rejected/untrusted content, never activatable |
| locks-leases | scoped coordination and lease records |

LOGICAL_STORAGE_ROOT_COUNT=14

WINDOWS_STORAGE_MAPPING=machine scope under ProgramData/STEMwerk/ComponentManager and user scope under LocalAppData/STEMwerk/ComponentManager, resolved by the Windows adapter

MACOS_STORAGE_MAPPING=machine scope under /Library/Application Support/STEMwerk/ComponentManager and user scope under the user Library/Application Support/STEMwerk/ComponentManager, resolved by the Darwin adapter

LINUX_STORAGE_MAPPING=machine scope under /var/lib/stemwerk/component-manager and user scope under XDG_STATE_HOME/stemwerk/component-manager with documented fallback, resolved by the Linux adapter

SAME_FILESYSTEM_STAGING_RULE=temporary staging is created inside the destination root's filesystem; cross-device publication is rejected, final publication is atomic replace plus required directory durability sync

PATH_TRAVERSAL_POLICY=accept only validated RelativePath components and verify the final opened object remains beneath its allowlisted root; never join untrusted absolute or dot-dot paths

SYMLINK_REPARSE_POLICY=no-follow for managed objects and every ancestor after root; symlinks, junctions and unexpected reparse points fail closed; adapter uses handle-relative checks where available

OWNERSHIP_POLICY=user and machine scopes are distinct and never silently combined; files use least privilege; shared artifacts carry explicit reference ownership; unknown ownership protects content from GC

STORAGE_LAYOUT_STATUS=RESOLVED

Immutable objects publish by content digest. An existing different object at the same identity is corruption. Incomplete installs stay in temporary staging and are never indexed as installed. Generation contents are never edited. Selectors are separate durable objects. Quarantine requires a new validated import path; it cannot be renamed directly into active state. Permission or ownership uncertainty blocks mutation.
