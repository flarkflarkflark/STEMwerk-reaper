#!/usr/bin/env python3
"""CPU-only stress benchmark: runs matmul on CPU for given sizes and iterations.
Produces stress_summary_{timestamp}.json and stress_merged_{timestamp}.csv in tests/bench_results.
"""
import os, time, json, argparse, statistics, csv

OUT_DIR = os.path.join('tests','bench_results')
os.makedirs(OUT_DIR, exist_ok=True)

def time_matmul_cpu(reps=3, size=2048):
    import time as _time
    out = {'device': 'cpu', 'reps': reps, 'size': size, 'times': []}
    try:
        import torch
        dtype = torch.float32
        a = torch.randn((size, size), device='cpu', dtype=dtype)
        b = torch.randn((size, size), device='cpu', dtype=dtype)
        for _ in range(1):
            _ = torch.matmul(a, b)
        for _ in range(reps):
            t0 = _time.time()
            _ = torch.matmul(a, b)
            _time.sleep(0.01)
            t1 = _time.time()
            out['times'].append(t1 - t0)
        out['median_s'] = float(statistics.median(out['times']))
        out['ok'] = True
    except Exception as e:
        out['ok'] = False
        out['error'] = str(e)
    return out

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--iterations', '-n', type=int, default=20)
    p.add_argument('--size', type=int, default=2048)
    p.add_argument('--reps', type=int, default=3)
    args = p.parse_args()

    timestamp = time.strftime('%Y%m%d-%H%M%S')
    all_results = []
    for it in range(1, args.iterations+1):
        iter_results = {'iteration': it, 'timestamp': time.strftime('%Y%m%d-%H%M%S'), 'results': []}
        print(f'CPU Iter {it}: benchmarking size={args.size} reps={args.reps}')
        r = time_matmul_cpu(reps=args.reps, size=args.size)
        iter_results['results'].append(r)
        fname = os.path.join(OUT_DIR, f'cpu_stress_iter_{timestamp}_{it}.json')
        with open(fname, 'w', encoding='utf-8') as f:
            json.dump(iter_results, f, indent=2)
        all_results.append(iter_results)

    # merged CSV and summary
    csvfile = os.path.join(OUT_DIR, f'cpu_stress_merged_{timestamp}.csv')
    with open(csvfile, 'w', newline='', encoding='utf-8') as cf:
        writer = csv.writer(cf)
        writer.writerow(['iteration','device','median_s','times','ok','error'])
        for it in all_results:
            for r in it['results']:
                writer.writerow([it['iteration'], r.get('device'), r.get('median_s',''), json.dumps(r.get('times',[])), r.get('ok',False), r.get('error','')])

    meds = [r['results'][0]['median_s'] for r in all_results if r['results'][0].get('ok')]
    summary = {'cpu': {'runs': len(meds), 'median_of_medians': float(statistics.median(meds)) if meds else None}}
    summary_file = os.path.join(OUT_DIR, f'cpu_stress_summary_{timestamp}.json')
    with open(summary_file, 'w', encoding='utf-8') as f:
        json.dump({'timestamp':timestamp, 'summary':summary}, f, indent=2)

    print('CPU summary:', json.dumps(summary, indent=2))
    print('CSV:', csvfile)
    print('Summary JSON:', summary_file)

if __name__ == '__main__':
    main()
