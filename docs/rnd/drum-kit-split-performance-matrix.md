# Drum Kit Split Performance Matrix

R&D benchmark summary for Drum Kit Split source scheduling and device policy.

## Results

| Scenario | Sources | Device mode | Actual backend | Max parallel | Wall time | Result |
| --- | ---: | --- | --- | ---: | ---: | --- |
| A | 2 | GPU parallel | cuda / cuda:0 | 2 | 30.576775034s | PASS |
| B | 2 | CPU sequential | cpu | 1 | 87.776427005s | PASS |
| C | 2 | GPU sequential | cuda / cuda:0 | 1 | 50.026665573s | PASS |
| D | 8 | GPU parallel | cuda / cuda:0 | 2 | 109.564367837s | PASS |
| E | 8 | GPU sequential | cuda / cuda:0 | 1 | 186.263799908s | PASS |

## Output Validation

The 8-source runs used `source_track` grouping. Each run produced:

- 4 source folders
- 24 stem tracks
- 48 imported drum stem media items
- successful MCP output validation
- successful undo validation

The 8-source GPU parallel run remained bounded and stable:

- active source count never exceeded 2
- batch import started only after `completed=8`
- output validation passed
- undo passed

## Speedups

| Comparison | Speedup |
| --- | ---: |
| 2-source GPU parallel vs GPU sequential | 1.636100x |
| 8-source GPU parallel vs GPU sequential | 1.700040x |
| 2-source GPU parallel vs CPU sequential | 2.870689x |

## Conclusions

- GPU parallel scheduling with `max_parallel=2` is validated.
- CPU and unknown device paths should remain `max_parallel=1`.
- `parallelProcessing=0` is useful as a sequential, safe, and debug mode.
- `parallelProcessing=1` should remain the default GPU batch policy.
- GPU parallelism provided consistent gains at both 2-source and 8-source scale.
