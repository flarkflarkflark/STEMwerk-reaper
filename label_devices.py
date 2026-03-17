import csv
import glob
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1] / "tests" / "bench_results"
mapf = root / "device_mapping.json"
if not mapf.exists():
    print("Mapping file not found:", mapf)
    raise SystemExit(1)
with open(mapf, "r", encoding="utf-8") as f:
    mapping = json.load(f)

written = []
for fn in glob.glob(str(root / "stress_merged_*.csv")):
    p = Path(fn)
    out = p.with_name(p.stem + "_labeled.csv")
    with open(p, newline='', encoding='utf-8') as inf, open(out, 'w', newline='', encoding='utf-8') as outf:
        reader = csv.reader(inf)
        writer = csv.writer(outf)
        header = next(reader)
        writer.writerow(header)
        # find device-like columns to replace in any column values
        for row in reader:
            newrow = [mapping.get(cell, cell) for cell in row]
            writer.writerow(newrow)
    written.append(str(out))

print("Wrote labeled CSVs:")
for w in written:
    print(w)
