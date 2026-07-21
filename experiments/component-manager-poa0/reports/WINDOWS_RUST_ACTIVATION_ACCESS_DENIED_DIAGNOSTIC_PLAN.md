# Windows Rust activation access-denied diagnostic plan

## Evidence basis

Run `29788593883` proved the in-process Rust SHA-256 route through
`artifact_verified` and `generation_built`. Both CMN-001 and the CMN-008
prerequisite then failed with Windows error 5. The hash fix is therefore
native-proven; this diagnostic starts at generation finalization.

## Activation timeline

| Step | Function | Operation | Source | Target | Handle state | Expected event |
|---|---|---|---|---|---|---|
| 1 | `install` | create generation staging directory | none | `generations/<id>.tmp` | none | none |
| 2 | `write_sync` | write and flush manifest | memory | `generation.json` | file closed on return | none |
| 3 | `install` | finalize generation directory | `<id>.tmp` | `<id>` | none | `generation_built` |
| 4 | `activate` | write and flush selector temp | memory | `state/active.tmp` | file closed on return | diagnostic result only |
| 5 | `activate` | rename selector | `state/active.tmp` | `state/active` | no application handle | diagnostic result only |
| 6 | `activate` | open parent directory | `state/` | `state/` | acquisition attempted | diagnostic handle event |
| 7 | `activate` | sync parent directory | `state/` | `state/` | directory handle open | diagnostic flush event |
| 8 | `install` | publish activation event | none | journal/stdout | no activation handle | `generation_activated` |
| 9 | `install` | update SQLite state | SQL | `state.db` | child process scoped per call | normal events |
| 10 | `install` | remove staging directory | staging path | none | no application handle | none |
| 11 | `install` | emit completion | none | journal/stdout | none | `op_completed` |

The first previously uninstrumented boundary is selector temp write through
parent-directory open/sync. Candidate steps are selector replacement,
parent-directory open, and parent-directory sync.

## Instrumentation and probes

`POA_ACTIVATION_DIAGNOSTIC=1` adds POA-only JSONL records around selector
write/flush, rename, directory-handle acquisition, directory sync, and failure
context. It records native paths, object state, attributes, raw OS/Win32 error,
and the last successful step. Twelve isolated NTFS probes cover file flush,
rename/replace, open-handle conflicts, directory rename/open/sync, cleanup with
an open child, selector replacement, read-only targets, and deny-share targets.

Per-case failure artifacts preserve summary, timeline, commands, stdout,
stderr, events, tree, attributes, handles, errors, journal, state, and case root.
Root-cause proof requires the failing activation record and the matching
primitive probe to agree on primitive and Win32 code.

This commit contains no functional fix, contract change, expectation change,
fixture change, schema change, or language decision.
