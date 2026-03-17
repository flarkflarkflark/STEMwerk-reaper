#!/usr/bin/env python3
"""Plot stress benchmark summaries found in tests/bench_results.
For each stress_summary_{timestamp}.json, finds corresponding stress_iter file to obtain matrix size,
then plots median_of_medians per device versus size.
Saves `tests/bench_results/stress_plot.png` and CSV.
"""
import os, json, glob, re, csv
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

OUT_DIR = os.path.join('tests','bench_results')
summary_files = sorted(glob.glob(os.path.join(OUT_DIR,'stress_summary_*.json')))
data = {}
sizes = set()

for sf in summary_files:
    base = os.path.basename(sf)
    m = re.match(r'stress_summary_(\d{8}-\d{6})\.json', base)
    if not m:
        continue
    ts = m.group(1)
    # find any stress_iter file for this timestamp to get size
    iter_glob = glob.glob(os.path.join(OUT_DIR, f'stress_iter_{ts}_*.json'))
    size = None
    if iter_glob:
        try:
            with open(iter_glob[0],'r',encoding='utf-8') as f:
                j = json.load(f)
                # j['results'] is list per device, each has 'size'
                if j.get('results') and isinstance(j['results'], list):
                    size = j['results'][0].get('size')
        except Exception:
            size = None
    # fallback: try to read the summary file itself
    try:
        with open(sf,'r',encoding='utf-8') as f:
            summ = json.load(f)
            summary = summ.get('summary', {})
    except Exception:
        continue
    if size is None:
        # try to infer size from any stress_iter file with similar timestamp prefix
        size = 0
    sizes.add(size)
    for dev, info in summary.items():
        if dev not in data:
            data[dev] = []
        data[dev].append((size, info.get('median_of_medians')))

if not data:
    print('No stress summary data found.')
    raise SystemExit(1)

# prepare plot
for dev in data:
    # sort by size
    lst = sorted([t for t in data[dev] if t[1] is not None], key=lambda x: x[0])
    if not lst:
        continue
    xs = [s for s,_ in lst]
    ys = [m for _,m in lst]
    plt.plot(xs, ys, marker='o', label=dev)

plt.xscale('log', base=2)
plt.xlabel('Matrix size (N)')
plt.ylabel('Median of medians (s)')
plt.title('Stress benchmark: median of medians vs matrix size')
plt.legend()
plt.grid(True, which='both', ls='--', lw=0.5)

out_png = os.path.join(OUT_DIR, 'stress_plot.png')
plt.savefig(out_png, dpi=150)

# write CSV
csv_out = os.path.join(OUT_DIR, 'stress_plot_data.csv')
with open(csv_out, 'w', newline='', encoding='utf-8') as cf:
    w = csv.writer(cf)
    w.writerow(['device','size','median_of_medians'])
    for dev in data:
        for size, med in sorted(data[dev], key=lambda x: x[0]):
            w.writerow([dev, size, med])

print('Wrote plot:', out_png)
print('Wrote CSV:', csv_out)
