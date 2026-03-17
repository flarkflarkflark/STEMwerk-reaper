import csv
import json
from pathlib import Path
import matplotlib.pyplot as plt

root = Path(__file__).resolve().parents[1] / "tests" / "bench_results"
plot_csv = root / "stress_plot_data.csv"
mapf = root / "device_mapping.json"
if not plot_csv.exists():
    print("Plot data not found:", plot_csv)
    raise SystemExit(1)
if not mapf.exists():
    print("Mapping file not found:", mapf)
    raise SystemExit(1)
with open(mapf, 'r', encoding='utf-8') as f:
    mapping = json.load(f)

# read plot data
rows = []
with open(plot_csv, newline='', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    for r in reader:
        rows.append(r)

# relabel device field if present
device_field = None
for name in ['device', 'Device', 'DeviceName']:
    if rows and name in rows[0]:
        device_field = name
        break
if device_field is None:
    # fallback: try first column
    device_field = list(rows[0].keys())[0]

# group by device label
groups = {}
for r in rows:
    dev = mapping.get(r[device_field], r[device_field])
    size = float(r.get('size') or r.get('Size') or r.get('matrix_size') or r.get('n') )
    val = float(r.get('median_of_medians') or r.get('median') or r.get('value') )
    groups.setdefault(dev, []).append((size, val))

# sort and plot
plt.figure(figsize=(8,5))
for dev, pts in groups.items():
    pts.sort()
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    plt.plot(xs, ys, marker='o', label=dev)
plt.xscale('log', base=2)
plt.yscale('log')
plt.xlabel('matrix size')
plt.ylabel('median_of_medians (s)')
plt.title('Stress comparison (labeled)')
plt.legend()
out_png = root / 'stress_plot_labeled.png'
plt.tight_layout()
plt.savefig(out_png)
print('Wrote labeled plot:', out_png)
# also write labeled CSV
out_csv = root / 'stress_plot_data_labeled.csv'
with open(out_csv, 'w', newline='', encoding='utf-8') as f:
    fieldnames = ['device','size','median_of_medians']
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    for dev, pts in groups.items():
        for size, val in sorted(pts):
            writer.writerow({'device': dev, 'size': size, 'median_of_medians': val})
print('Wrote labeled CSV:', out_csv)
