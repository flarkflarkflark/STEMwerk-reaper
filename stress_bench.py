#!/usr/bin/env python3
"""Run repeated benchmarks with configurable matmul size and iterations.
Saves per-iteration JSONs to tests/bench_results and writes a summary JSON and CSV.
"""
import os, time, json, argparse, statistics, csv

OUT_DIR = os.path.join('tests','bench_results')
os.makedirs(OUT_DIR, exist_ok=True)

def time_matmul(device, reps=3, size=2048):
    import time as _time
    out = {'device': str(device), 'reps': reps, 'size': size, 'times': []}
    try:
        import torch
        dtype = torch.float32
        a = torch.randn((size, size), device=device, dtype=dtype)
        b = torch.randn((size, size), device=device, dtype=dtype)
        # warmup
        for _ in range(1):
            _ = torch.matmul(a, b)
        for _ in range(reps):
            t0 = _time.time()
            _ = torch.matmul(a, b)
            # best-effort sync
            try:
                if isinstance(device, str) and device.startswith('cuda'):
                    torch.cuda.synchronize()
            except Exception:
                pass
            _time.sleep(0.01)
            t1 = _time.time()
            out['times'].append(t1 - t0)
        out['median_s'] = float(statistics.median(out['times']))
        out['ok'] = True
    except Exception as e:
        out['ok'] = False
        out['error'] = str(e)
    return out

def find_dml_devices():
    devs = []
    try:
        import torch_directml
        # try device_count
        try:
            cnt = int(torch_directml.device_count())
        except Exception:
            try:
                cnt = int(getattr(torch_directml, 'get_device_count', lambda: 0)() or 0)
            except Exception:
                cnt = None
        if cnt and cnt > 0:
            rng = range(cnt)
        else:
            rng = range(8)
        for i in rng:
            try:
                d = torch_directml.device(i)
            except Exception:
                break
            devs.append(d)
        return devs
    except Exception:
        # fallback to cpu
        import torch
        return ['cpu']

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--iterations', '-n', type=int, default=5)
    p.add_argument('--size', type=int, default=2048)
    p.add_argument('--reps', type=int, default=3)
    args = p.parse_args()

    devices = find_dml_devices()
    timestamp = time.strftime('%Y%m%d-%H%M%S')
    all_results = []

    for it in range(1, args.iterations+1):
        iter_results = {'iteration': it, 'timestamp': time.strftime('%Y%m%d-%H%M%S'), 'results': []}
        for d in devices:
            print(f'Iter {it}: benchmarking {d} size={args.size} reps={args.reps}')
            res = time_matmul(d, reps=args.reps, size=args.size)
            iter_results['results'].append(res)
        fname = os.path.join(OUT_DIR, f'stress_iter_{timestamp}_{it}.json')
        with open(fname, 'w', encoding='utf-8') as f:
            json.dump(iter_results, f, indent=2)
        print('Saved', fname)
        all_results.append(iter_results)

    # write merged CSV
    csvfile = os.path.join(OUT_DIR, f'stress_merged_{timestamp}.csv')
    with open(csvfile, 'w', newline='', encoding='utf-8') as cf:
        writer = csv.writer(cf)
        writer.writerow(['iteration','device','median_s','times','ok','error'])
        for it in all_results:
            for r in it['results']:
                writer.writerow([it['iteration'], r.get('device'), r.get('median_s',''), json.dumps(r.get('times',[])), r.get('ok',False), r.get('error','')])

    # summary: median of medians per device
    summary = {}
    dev_to_medians = {}
    for it in all_results:
        for r in it['results']:
            dev = r.get('device')
            if dev not in dev_to_medians:
                dev_to_medians[dev] = []
            if r.get('ok'):
                dev_to_medians[dev].append(r.get('median_s'))
    for dev, meds in dev_to_medians.items():
        if meds:
            summary[dev] = {'runs': len(meds), 'median_of_medians': float(statistics.median(meds))}
        else:
            summary[dev] = {'runs':0, 'median_of_medians': None}

    summary_file = os.path.join(OUT_DIR, f'stress_summary_{timestamp}.json')
    with open(summary_file, 'w', encoding='utf-8') as f:
        json.dump({'timestamp':timestamp, 'summary':summary}, f, indent=2)

    print('\nSummary:')
    print(json.dumps(summary, indent=2))
    print('CSV:', csvfile)
    print('Summary JSON:', summary_file)


if __name__ == '__main__':
    main()
