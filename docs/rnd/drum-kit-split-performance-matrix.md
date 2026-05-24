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

## 8-source GPU Parallel Repeatability

| Run | Run dir | Wall time | Total source audio | Realtime factor | Per-source wall time | Backend/device | Max parallel | Max active | Output | Undo |
| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | --- | --- |
| Original D | n/a | 109.564367837s | n/a | n/a | n/a | cuda / cuda:0 | 2 | 2 | PASS | PASS |
| D1 repeat | `/tmp/stemwerk-drumsep-workflow-prototype-20260523-210757` | 108.027191862s | 24.6428671428572s | 0.228117x | 13.50339898275s | cuda / cuda:0 | 2 | 2 | PASS | PASS |
| D2 repeat | `/tmp/stemwerk-drumsep-workflow-prototype-20260523-211148` | 107.979191725s | 24.6428671428572s | 0.228219x | 13.497398965625s | cuda / cuda:0 | 2 | 2 | PASS | PASS |

Repeatability summary:

- average wall time: 108.523583808s
- min/max wall time: 107.979191725s / 109.564367837s
- spread: 1.585176112s, about 1.460674% of average
- D2 was only 1.000445x faster than D1
- no strong warm-cache effect was visible
- `max_parallel=2` remained bounded, stable, and recommended for GPU batch policy

## Long-source 2-source (30s each) Benchmarks

| Run | Run dir | Wall time | Total source audio | Realtime factor | Slower-than-realtime | Backend/device | Max parallel | Output | Undo | Bounds restore |
| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | --- | --- | --- |
| F: GPU parallel | `/tmp/stemwerk-drumsep-workflow-prototype-20260523-234311` | 64.654328343s | 60s | 0.9277x | 1.0776x | cuda / cuda:0 | 2 | PASS | PASS | PASS |
| G: GPU sequential | `/tmp/stemwerk-drumsep-workflow-prototype-20260524-010749` | 83.881323097001s | 60s | 0.715296299399278x | 1.3980220516166832x | cuda / cuda:0 | 1 | PASS | PASS | PASS |

Long-source comparison summary:

- F is about 1.297x faster than G by wall time.
- Long-source GPU parallel is much closer to realtime than the short-clip tests.
- Short clips are more heavily affected by fixed overhead.
- `max_parallel=2` remains recommended for GPU workloads.
- CPU/unknown paths remain `max_parallel=1`.
- `parallelProcessing=0` remains useful as safe/debug/low-load sequential mode.

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
- Absolute realtime factor for short clips is heavily affected by fixed overhead.
- Longer-source results now confirm more realistic near-realtime behavior on GPU, especially with parallel scheduling.
