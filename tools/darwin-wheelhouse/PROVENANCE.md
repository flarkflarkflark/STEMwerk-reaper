# STEMwerk managed darwin wheelhouse — provenance

Deze wheels onder `scripts/reaper/vendor/wheels/darwin-{arm64,x86_64}-cp312/` zijn de managed
wheelhouse voor macOS Repair/Rebuild (2.3.1.0). Ze dekken precies de packages waarvoor PyPI
géén bruikbare cp312-macOS-wheel heeft (diffq) of waarvan de PyPI-wheel kapot is voor een van
de architecturen (samplerate), plus het eigen stemwerk_core-wiel. Alles overige komt online
via PyPI (torch-stack, numpy, audio-separator, onnxruntime e.a. — zie constraints/macos.txt
en constraints/macos-intel.txt).

## arm64 (herkomst: STEMwerk-2.3.0.6-bundled-apple-silicon.pkg, byte-exact)

Pkg sha256: `18b7ab307bcf06fe8060d9516d99d0e280f7bde1fb717d8cc1fd888f747eac71`
(verifieerbaar tegen `installer/SHA256SUMS-2.3.0.6.txt`; geëxtraheerd met
`pkgutil --expand-full`).

| bestand | sha256 | bytes |
|---|---|---|
| diffq-0.2.4-cp312-cp312-macosx_11_0_arm64.whl | `bf65321f2360e0be40bc6441e299531aec547eb0024382182c179206e37d29db` | 111.455 |
| samplerate-0.1.0-py3-none-macosx_11_0_arm64.whl | `adb4c3e63fae815e6856e6a75d24d09e47f614d478316dc4cad479301d685531` | 4.043.848 |
| stemwerk_core-0.1.1-py3-none-any.whl | `e4555cd9179a5927c0121b140e3f98c36bfd6d4a5bb7b7d25a1786be7250a981` | 10.795 |

Totaal arm64: 4.166.098 B (≈ 4,0 MB).

## x86_64 (gereproduceerd via recept; stemwerk_core uit dezelfde 2.3.0.6-payload)

| bestand | sha256 | bytes |
|---|---|---|
| diffq-0.2.4-cp312-cp312-macosx_11_0_x86_64.whl | `51a41e40354aa306a810fb8120ca2483acf01fd9b407d01a0a52e9cba749b257` | 107.690 |
| samplerate-0.1.0-py3-none-macosx_11_0_x86_64.whl | `3d5bcd3b72cf45b9d447cd8b5903b3b62b32fe9405384d9388eecb197a4a78f6` | 4.028.665 |
| stemwerk_core-0.1.1-py3-none-any.whl | `e4555cd9179a5927c0121b140e3f98c36bfd6d4a5bb7b7d25a1786be7250a981` | 10.795 |

Totaal x86_64: 4.147.150 B (≈ 4,0 MB).

## Recept (x86_64)

`tools/darwin-wheelhouse/build_x86_64_wheels.sh <output-dir>` — vereist macOS met CLT en een
python3.12 (env `PYTHON312` overstuurbaar). Stappen:

1. **diffq 0.2.4**: sdist van PyPI (`diffq-0.2.4.tar.gz`, sha256
   `049064861e974ebf00d0badab8b324c775037371419eda3150985b9d477b5bd2`) → cross-build
   (`ARCHFLAGS="-arch x86_64"`, `MACOSX_DEPLOYMENT_TARGET=11.0`, `LDFLAGS="-Wl,-S"`,
   vaste buildmap) in geïsoleerde env met gepinde `cython==3.2.8` + `setuptools==83.0.0` →
   retag naar `macosx_11_0_x86_64` met RECORD-regeneratie en genormaliseerde zip-timestamps.
   Inhoudscontrole: `bitpack.cpython-312-darwin.so` is `Mach-O x86_64` (D7-bewijsvoering).
   `LC_UUID` blijft aanwezig omdat recente Intel macOS-versies een native extension zonder
   deze load command weigeren te laden. Het recept controleert dit fail-closed met `otool -l`.
   OSO-symbolen (object-mtimes) worden gestript (`-S`) en de buildmap is vast
   (pad-embedding).

   De RC3-remediatie is op 2026-10-06 tweemaal byte-identiek herbouwd op een arm64-host met
   managed Python 3.12.13, Apple clang 21.0.0 (`clang-2100.3.34.2`) en macOS SDK 27.0.
   De resulterende x86_64-extension heeft `LC_BUILD_VERSION minos 11.0`, een `LC_UUID`,
   en importeert onder de bestaande Python 3.12.13 Rosetta-harness met Intel torch 2.2.2.
2. **samplerate 0.1.0**: PyPI-wheel (`samplerate-0.1.0-py2.py3-none-any.whl`, sha256
   `f55e5c9d0a8ba3c82a53b7d9c34a2d145439c61166a7f310efaec88f2781b8f8`) → retag naar
   `py3-none-macosx_11_0_x86_64` (zelfde deterministische herschrijver; de PyPI-inhoud —
   x86_64 `libsamplerate.dylib` — is correct voor Intel maar werd door de arch-loze tag óók op
   arm64 geïnstalleerd; zie D7 in de release-notes). Inhoudscontrole: dylib is `Mach-O x86_64`.
3. **stemwerk_core 0.1.1**: niet herbouwd — canonieke artifact uit de 2.3.0.6-payload
   (byte-exact; zelfde wheel voor beide archs, pure python).

De arm64-wheels herbouwen we NIET: de 2.3.0.6-payload is de geaudite referentie
("round-2 union rebuild", zie `installer/SHA256SUMS-2.3.0.6.txt`). Het recept dient als
toekomstpad voor nieuwe versies; herbouw van arm64-diffq kan met hetzelfde script op
aarch64-native wijze (ARCHFLAGS weglaten).

## Licentie-notitie

- diffq 0.2.4 — MIT (Copyright (c) Facebook, Inc. and its affiliates); zie `THIRD_PARTY_NOTICES.md`.
- samplerate 0.1.0 — BSD-3-Clause (Copyright (c) 2014, HGN Software GmbH); bevat prebuilt
  libsamplerate (BSD, Erik de Castro Lopo); zie `THIRD_PARTY_NOTICES.md`.
- stemwerk_core 0.1.1 — STEMwerk zelf (MIT), bron: `scripts/reaper/vendor/stemwerk-core/`.

## Distributie-regel (diffq-les)

Elke wheel hier heeft exact één `<source>`-regel in `index.xml` (anders distribueert ReaPack
hem niet). De parity-gate in `tools/release_gate.py` (`check_vendor_wheel_index_parity`) plus
`tests/test_dependency_constraints.py::test_vendor_wheels_have_exactly_one_index_source`
bewezen dit per release.
