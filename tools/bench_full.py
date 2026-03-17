#!/usr/bin/env python3
"""
Full lightweight benchmark: CPU, CUDA (if available), DirectML adapters (if torch-directml installed), MPS (if available).
Saves JSON to `tests/bench_results/bench_full.json` and prints summary.
"""
import json
import os
import time
import math
import csv

OUT_DIR = os.path.join('tests','bench_results')
os.makedirs(OUT_DIR, exist_ok=True)
OUT_FILE = os.path.join(OUT_DIR, 'bench_full.json')

results = {
    'platform': None,
    'python': None,
    'torch': None,
    'tests': []
}

try:
    import platform
    results['platform'] = platform.system()
    results['python'] = platform.python_version()
except Exception:
    pass

try:
    import torch
    results['torch'] = getattr(torch, '__version__', str(torch))
except Exception as e:
    results['torch_error'] = str(e)
    print('Torch import failed:', e)


def time_matmul(device, reps=3, size=1024):
    out = {'device': str(device), 'reps': reps, 'size': size}
    try:
        import torch
        dtype = torch.float32
        # create tensors on device
        a = torch.randn((size, size), device=device, dtype=dtype)
        b = torch.randn((size, size), device=device, dtype=dtype)
        # warmup
        for _ in range(1):
            c = torch.matmul(a, b)
        # timing
        times = []
        for _ in range(reps):
            t0 = time.time()
            c = torch.matmul(a, b)
            # best-effort syncs
            try:
                if isinstance(device, str) and device.startswith('cuda'):
                    torch.cuda.synchronize()
            except Exception:
                pass
            time.sleep(0.01)
            t1 = time.time()
            times.append(t1 - t0)
        out['times'] = times
        out['median_s'] = float(sorted(times)[len(times)//2])
        out['ok'] = True
    except Exception as e:
        out['ok'] = False
        out['error'] = str(e)
    return out


# CPU
try:
    import torch
    cpu_res = time_matmul('cpu')
    results['tests'].append(cpu_res)
except Exception as e:
    results['tests'].append({'device':'cpu','ok':False,'error':str(e)})

# CUDA devices
try:
    import torch
    if torch.cuda.is_available():
        for i in range(torch.cuda.device_count()):
            dev = f'cuda:{i}'
            res = time_matmul(dev)
            results['tests'].append(res)
    else:
        results['tests'].append({'device':'cuda','ok':False,'reason':'no_cuda'})
except Exception as e:
    results['tests'].append({'device':'cuda','ok':False,'error':str(e)})

# MPS (Apple)
try:
    import torch
    if getattr(torch.backends, 'mps', None) is not None and torch.backends.mps.is_available():
        res = time_matmul('mps')
        results['tests'].append(res)
    else:
        results['tests'].append({'device':'mps','ok':False,'reason':'no_mps'})
except Exception as e:
    results['tests'].append({'device':'mps','ok':False,'error':str(e)})

# DirectML via torch_directml - enumerate adapters safely
try:
    import importlib
    if importlib.util.find_spec('torch_directml') is not None:
        import torch_directml
        # preferred: query device count if available
        device_count = None
        try:
            # some builds expose device_count()
            device_count = int(torch_directml.device_count())
        except Exception:
            try:
                # fallback name
                device_count = int(getattr(torch_directml, 'get_device_count', lambda: None)() or 0)
            except Exception:
                device_count = None

        found = 0
        if device_count and device_count > 0:
            for i in range(device_count):
                try:
                    d = torch_directml.device(i)
                except Exception as e:
                    results['tests'].append({'device':f'dml:{i}','ok':False,'error':str(e)})
                    continue
                try:
                    res = time_matmul(d)
                    results['tests'].append(res)
                    found += 1
                except Exception as e:
                    results['tests'].append({'device':f'dml:{i}','ok':False,'error':str(e)})
        else:
            # fallback: probe indices until an out-of-range error appears
            max_probe = 16
            for i in range(max_probe):
                try:
                    d = torch_directml.device(i)
                except Exception as e:
                    msg = str(e)
                    # stop probing when index is out of range
                    if 'must be in range' in msg or 'Invalid device_id' in msg or 'out of range' in msg:
                        break
                    results['tests'].append({'device':f'dml:{i}','ok':False,'error':msg})
                    continue
                try:
                    res = time_matmul(d)
                    results['tests'].append(res)
                    found += 1
                except Exception as e:
                    results['tests'].append({'device':f'dml:{i}','ok':False,'error':str(e)})
            if found == 0:
                results['tests'].append({'device':'dml','ok':False,'reason':'no_adapters_worked'})
    else:
        results['tests'].append({'device':'dml','ok':False,'reason':'torch_directml_not_installed'})
except Exception as e:
    results['tests'].append({'device':'dml','ok':False,'error':str(e)})

# Save results
with open(OUT_FILE, 'w', encoding='utf-8') as f:
    json.dump(results, f, indent=2)

print('Benchmark complete. Results saved to', OUT_FILE)
print(json.dumps(results, indent=2))

# Also write a compact CSV summary for easy inspection
CSV_FILE = os.path.join(OUT_DIR, 'bench_full.csv')
try:
    with open(CSV_FILE, 'w', newline='', encoding='utf-8') as cf:
        writer = csv.writer(cf)
        writer.writerow(['device', 'ok', 'median_s', 'times', 'error', 'reason'])
        for t in results.get('tests', []):
            device = t.get('device')
            ok = t.get('ok', False)
            median = t.get('median_s', '')
            times = json.dumps(t.get('times', []))
            error = t.get('error', '')
            reason = t.get('reason', '')
            writer.writerow([device, ok, median, times, error, reason])
    print('CSV summary saved to', CSV_FILE)
except Exception as e:
    print('Failed to write CSV:', e)
