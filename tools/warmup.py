#!/usr/bin/env python3
import os, time, json
os.makedirs(os.path.join('tests','bench_results'), exist_ok=True)

def time_matmul(device, reps=5, size=1024):
    import torch, time
    out = {'device': str(device), 'reps': reps, 'size': size, 'times': []}
    dtype = torch.float32
    # create tensors
    a = torch.randn((size, size), device=device, dtype=dtype)
    b = torch.randn((size, size), device=device, dtype=dtype)
    # warmup
    for _ in range(2):
        _ = torch.matmul(a, b)
        try:
            if isinstance(device, str) and device.startswith('cuda'):
                torch.cuda.synchronize()
        except Exception:
            pass
        time.sleep(0.01)
    # timing
    for _ in range(reps):
        t0 = time.time()
        _ = torch.matmul(a, b)
        try:
            if isinstance(device, str) and device.startswith('cuda'):
                torch.cuda.synchronize()
        except Exception:
            pass
        time.sleep(0.01)
        t1 = time.time()
        out['times'].append(t1 - t0)
    out['median_s'] = float(sorted(out['times'])[len(out['times'])//2])
    return out

def find_devices():
    try:
        import importlib
        if importlib.util.find_spec('torch_directml') is not None:
            import torch_directml
            # try device_count()
            try:
                cnt = int(torch_directml.device_count())
            except Exception:
                cnt = 1
            devs=[]
            for i in range(max(1,cnt)):
                try:
                    devs.append(torch_directml.device(i))
                except Exception:
                    pass
            if devs:
                return devs
    except Exception:
        pass
    # fallback to cpu
    import torch
    return ['cpu']

if __name__ == "__main__":
    devs = find_devices()
    results=[]
    # warmup phase: run small matmuls repeatedly for ~30s
    print("Warming up devices:", [str(d) for d in devs])
    for d in devs:
        for _ in range(6):
            _ = time_matmul(d, reps=1, size=512)
    # full runs
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    for d in devs:
        print("Benchmarking", d)
        r = time_matmul(d, reps=5, size=1024)
        results.append(r)
    outf = os.path.join('tests','bench_results', f'warmup_bench_{timestamp}.json')
    with open(outf, 'w', encoding='utf-8') as f:
        json.dump({'timestamp':timestamp, 'results':results}, f, indent=2)
    print("Saved:", outf)
    print(json.dumps(results, indent=2))