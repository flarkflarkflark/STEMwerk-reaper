Benchmark results and notes

Files
- `stress_*` JSONs and `stress_merged_*.csv`: per-iteration and merged GPU stress runs.
- `cpu_stress_*` CSV/JSON: CPU baselines run with `tools/cpu_stress.py`.
- `device_mapping.json`: maps `privateuseone:N` to physical GPU names.
- `stress_plot_labeled.png`, `stress_plot_data_labeled.csv`: labeled comparison plot and CSV.

How to reproduce (from repo root, venv active):

```powershell
.\.venv\Scripts\python.exe tools/inspect_dml.py
.\.venv\Scripts\python.exe tools/warmup.py --iterations 5 --size 2048
.\.venv\Scripts\python.exe tools/stress_bench.py --iterations 20 --size 2048 --reps 3
.\.venv\Scripts\python.exe tools/stress_bench.py --iterations 20 --size 4096 --reps 3
.\.venv\Scripts\python.exe tools/stress_bench.py --iterations 20 --size 8192 --reps 3
# large run (may require >12GB VRAM per device)
.\.venv\Scripts\python.exe tools/stress_bench.py --iterations 10 --size 16384 --reps 2
.\.venv\Scripts\python.exe tools/plot_with_labels.py
```

Interpretation (summary):
- Devices: `privateuseone:0` → AMD Radeon RX 9070 (external); `privateuseone:1` → AMD Radeon 780M (internal).
- For small/medium sizes (2048–8192) both GPUs show very similar fast matmul times (~0.0105–0.0108 s median).
- CPU baselines are significantly slower (example: 0.042 s @2048, 0.256 s @4096, 2.288 s @8192).
- Large-size results (16384): RX 9070 median ≈ 0.01384 s (10 runs); 780M had fewer successful runs in this session (1 successful run recorded, median ≈ 0.01283 s) — may indicate occasional OOM or scheduling issues on the internal adapter; consider repeating with fewer reps or verifying available VRAM.

Notes and next steps:
- If you want reproducible release artifacts, push `tests/bench_results/` to a release or attach CSV/PNG files to GitHub Releases.
- For broader comparison, run identical tests on an NVIDIA machine (use CUDA device names) and merge CSVs.
- Be cautious with `torch`/`torchaudio` version mismatches after installing `torch-directml` (we used torch 2.4.1 for adapter compatibility).

