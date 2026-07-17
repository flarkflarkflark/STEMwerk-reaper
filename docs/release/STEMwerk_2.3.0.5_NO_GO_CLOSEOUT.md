# STEMwerk 2.3.0.5 NO-GO Closeout

## 1. Verdict

```text
RELEASE_2_3_0_5=NO_GO
NEXT_TARGET=2.4.0
FINAL_2305_MAIN_SHA=b991b3347ae548d1b5a7ea6274d0ee68dfd768db
```

STEMwerk 2.3.0.5 will not be tagged or published. This file closes the planned
release and preserves its validated work as the baseline for 2.4.0.

## 2. Why 2.3.0.5 stopped

The 2.3 hotfix grew into shared runtime, payload, and model-resolution work.
macOS and Windows compatibility-config materialization was implemented and
validated because those platforms distribute an official bundled canonical
source. Linux runtime guard behavior requires canonical LF content, but an
existing Linux runtime contains the exact known legacy CRLF variant:

| Variant | Size | SHA-256 |
| --- | ---: | --- |
| Legacy CRLF | 2417 | `17d1649a227f841165bdb4c11a42082898192a1ea3ceab7e7e0b9293d6589dd6` |
| Canonical LF | 2331 | `b7165bb73a0b08df49ac4ed5fe7424e29bf2f707b5878300f729a7e92671257a` |

The shared contract identifies the legacy file as a
`supported_migration_source`. Linux, however, does not distribute the canonical
source: it is absent from ReaPack, the online-minimal stage, and all Linux
offline payloads. The Linux bootstrap therefore cannot officially migrate the
known legacy file. Existing Linux runtimes can remain fail-closed before Direct
Kit or Kit Split.

A correct fix requires Linux payload, staging, inventory, bootstrap, and
installer changes followed by new cross-platform validation. Those are payload
and installer architecture changes, not a bounded hotfix, so they exceed the
2.3.0.5 scope.

## 3. Stop criterion and override

```text
The original “one remaining product fix” stop criterion was
explicitly overridden once to complete Linux platform parity.

That override was consumed.

The implementation tripwire then proved that Linux parity required
new payload/distribution semantics rather than a 1:1 bootstrap-only
port.

No second override is permitted.

All remaining product-code work moves to 2.4.
```

```text
2.3.0.5 PRODUCT-FIX OVERRIDE CONSUMED
NO FURTHER 2.3.0.5 PRODUCT-CODE FIXES PERMITTED
ANY ADDITIONAL REQUIRED PRODUCT-CODE CHANGE MOVES TO 2.4
```

## 4. Validated green state

### macOS Apple Silicon

- Native M1 baseline passed.
- Fresh rebuild, Repair, and convergence passed.
- Normal stems, Direct Kit, and Kit Split passed.
- MPS and canonical compatibility config passed.
- No-network behavior and model immutability passed.

### Windows AMD and DirectML

- Normal stems passed 4/4.
- Direct Kit and Kit Split each passed 6/6.
- Compatibility payload and idempotent setup passed.
- The canonical checkpoint resolver passed.
- No processing-time `copy_alias` occurred.
- B-to-C model immutability passed.

### Linux AMD and ROCm

- The static matrix and runtime preflight passed.
- Normal stems passed 4/4 on RX 9070.
- Direct Kit stopped before inference on the legacy config.
- No runtime or model mutation occurred.
- No network download occurred.

## 5. Findings that are not bugs

- NumPy 2.4.4 with Numba 0.66.0 is healthy on the investigated current-main
  runtime. The old pre-fix Lua gate incorrectly rejected this combination. Do
  not apply a NumPy downgrade.
- The Mateush1982 bundle showed script/runtime skew. The canonical resolver fix
  covers the model-ID mapping seen in that build.

## 6. Open work for 2.4

- Define one shared cross-platform DrumSep asset and payload contract.
- Include the canonical compatibility config in the Linux online payload and
  the Linux offline CPU, ROCm, and NVIDIA payloads.
- Update Linux stages, builders, inventories, and audits.
- Implement Linux bootstrap materialization with these exact states: missing
  creates the file; canonical is a no-op; exact legacy migrates atomically;
  unknown content fails closed.
- Test clean install, upgrade, and same-version Repair.
- Validate Windows, macOS, and Linux contract parity across CPU, DirectML,
  ROCm, CUDA, and MPS.
- Complete macOS Intel, Windows CPU offline, Linux NVIDIA, and Windows NVIDIA
  coverage.
- Add ReaPack/package/installer skew diagnostics and clear remediation for a
  runtime older than its scripts.
- Keep Vocals HQ and model-registry-v2 activation behind the 2.4 gate.

## 7. User remediation

### Mateush1982

- Do not install `numpy<2.4` or manually alter the virtual environment.
- Use the fixed scripts.
- On Apple Silicon, use the official macOS package for Repair when a bundled
  payload is required.
- Create a new support bundle after the definitive update.

### Linux 2.3.0.4 with legacy config

- Do not publish general manual newline conversion as the official solution.
- Existing normal-stems processing remains usable.
- Direct Kit and Kit Split may stop fail-closed on the legacy config.
- The structural solution is assigned to 2.4.

## 8. Release-process lesson

Do not distribute version-bumped builds as final before candidate freeze. Use
`-dev`, `-rcN`, and a commit/build ID until the platform matrix has qualified a
release candidate. Record any branch-protection bypass explicitly, and only
name a release candidate after that matrix has passed.
