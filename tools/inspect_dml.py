#!/usr/bin/env python3
"""Inspect torch-directml availability and probe adapters."""
import json


def main():
    out = {}
    try:
        try:
            import torch_directml
        except Exception:
            out['torch_directml_installed'] = False
            print(json.dumps(out, indent=2))
            return
        out['torch_directml_installed'] = True
        try:
            import torch
            out['torch_version'] = getattr(torch, '__version__', None)
        except Exception:
            out['torch_error'] = 'torch import failed'
            print(json.dumps(out, indent=2))
            return

        out['torch_directml_version'] = getattr(torch_directml, '__version__', None)

        # Determine device count (best effort)
        device_count = None
        try:
            device_count = int(torch_directml.device_count())
        except Exception:
            try:
                device_count = int(getattr(torch_directml, 'get_device_count', lambda: 0)() or 0)
            except Exception:
                device_count = None

        devices = []
        probe_range = range(device_count) if device_count and device_count > 0 else range(16)
        for i in probe_range:
            info = {'index': i}
            try:
                d = torch_directml.device(i)
                info['device_repr'] = repr(d)
                info['device_str'] = str(d)
            except Exception as e:
                info['ok'] = False
                info['error'] = str(e)
                devices.append(info)
                msg = str(e).lower()
                if 'must be in range' in msg or 'invalid device_id' in msg or 'out of range' in msg:
                    break
                continue

            # try small allocation and matmul
            try:
                a = torch.randn((64, 64), device=d, dtype=torch.float32)
                b = torch.randn((64, 64), device=d, dtype=torch.float32)
                _ = torch.matmul(a, b)
                info['ok'] = True
            except Exception as e:
                info['ok'] = False
                info['error'] = str(e)
            devices.append(info)

        out['devices'] = devices
    except Exception as e:
        out['error'] = str(e)
    print(json.dumps(out, indent=2))


if __name__ == '__main__':
    main()
