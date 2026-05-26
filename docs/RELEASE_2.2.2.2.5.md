# STEMwerk v2.2.2.2.5

Release date: 2026-05-26

This patch release focuses on processing-summary classification accuracy in support bundles.

## Support bundle processing summary

- Fixes processing-summary classification so stale model-download/checksum errors no longer override successful runs.
- Classifies runs with `exit_code=0` and DONE/Complete/stems evidence as successful in processing summaries.
- Classifies `user_cancel` / exit code `143` as cancelled and avoids mislabeling those runs as model-download failures without current evidence.
