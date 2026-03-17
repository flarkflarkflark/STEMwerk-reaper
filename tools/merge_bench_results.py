#!/usr/bin/env python3
"""Merge all JSON bench results in tests/bench_results into a single CSV.
Writes tests/bench_results/merged_results.csv
"""
import os, json, csv

OUT_DIR = os.path.join('tests','bench_results')
os.makedirs(OUT_DIR, exist_ok=True)

files = sorted([f for f in os.listdir(OUT_DIR) if f.endswith('.json')])
rows = []
for fn in files:
    path = os.path.join(OUT_DIR, fn)
    try:
        with open(path,'r',encoding='utf-8') as f:
            j = json.load(f)
    except Exception:
        continue
    # support both bench_full structure and warmup files
    if isinstance(j, dict) and 'tests' in j:
        entries = j['tests']
    elif isinstance(j, dict) and 'results' in j:
        entries = j['results']
    elif isinstance(j, list):
        entries = j
    else:
        continue
    for e in entries:
        device = e.get('device')
        median = e.get('median_s', '')
        times = e.get('times', [])
        rows.append({'file':fn,'device':device,'median_s':median,'times':json.dumps(times)})

OUT_CSV = os.path.join(OUT_DIR,'merged_results.csv')
with open(OUT_CSV,'w',newline='',encoding='utf-8') as cf:
    writer = csv.DictWriter(cf, fieldnames=['file','device','median_s','times'])
    writer.writeheader()
    for r in rows:
        writer.writerow(r)

print('Merged', len(rows), 'rows into', OUT_CSV)
