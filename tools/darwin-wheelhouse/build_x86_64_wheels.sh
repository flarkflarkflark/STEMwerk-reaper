#!/usr/bin/env bash
# Reproduceerbare build van de STEMwerk managed darwin-x86_64-cp312 wheels.
#
# Produceert deterministische wheels (sha256 vastgelegd in PROVENANCE.md):
#   diffq-0.2.4-cp312-cp312-macosx_11_0_x86_64.whl      (cross-build uit PyPI-sdist)
#   samplerate-0.1.0-py3-none-macosx_11_0_x86_64.whl    (repack van PyPI-inhoud, platform-getagd)
#
# Waarom: diffq heeft op PyPI geen cp312-macOS-wheels (sdist-only → source-build → Xcode CLT
# bij eindgebruikers = ondeterministisch). De PyPI-samplerate-wheel is py2.py3-none-any maar
# bevat een x86_64-only dylib; wij taggen hem expliciet als macosx_11_0_x86_64 zodat pip hem
# alleen op Intel kiest en hij nooit op arm64 belandt (D7).
#
# Determinisme: de retag herschrijft de zip direct (entries in oorspronkelijke volgorde met
# hun originele ZipInfo/timestamps; alleen het dist-info/WHEEL-entry wordt vervangen). Daarmee
# is de output uitsluitend een functie van de input-bytes, niet van het bestandssysteem.
# De diffq-binary hangt daarnaast af van de lokale clang/SDK-toolchain; zie PROVENANCE.md.
#
# Gebruik:
#   tools/darwin-wheelhouse/build_x86_64_wheels.sh <output-dir>
# Optionele env: PYTHON312=/pad/naar/python3.12 (default: managed python of python3.12 uit PATH)
set -euo pipefail

OUT_DIR="${1:?gebruik: $0 <output-dir>}"
# VASTE werkmap: Cython/clang embedden het build-pad (__FILE__) in de .so — een constant pad
# is daarom een voorwaarde voor run-op-run identieke bytes.
WORK="${TMPDIR:-/tmp}/stemwerk-darwin-wheels-work"
rm -rf "${WORK}"
mkdir -p "${WORK}" "${OUT_DIR}"

# --- Vastgepinde upstream-artefacten (PyPI) -----------------------------------
DIFFQ_VERSION="0.2.4"
DIFFQ_SDIST_URL="https://files.pythonhosted.org/packages/5a/fd/4c58807bf855c5929ffa6da55f26dd6b9ae462a4193f5e09cc49fbbfd451/diffq-0.2.4.tar.gz"
DIFFQ_SDIST_SHA256="049064861e974ebf00d0badab8b324c775037371419eda3150985b9d477b5bd2"
SAMPLERATE_VERSION="0.1.0"
SAMPLERATE_WHEEL_URL="https://files.pythonhosted.org/packages/0c/3c/4c1aa376332d18e708dcc3289e4dbdd2c508bcac1b8eb1b35b73092fa00f/samplerate-0.1.0-py2.py3-none-any.whl"
SAMPLERATE_WHEEL_SHA256="f55e5c9d0a8ba3c82a53b7d9c34a2d145439c61166a7f310efaec88f2781b8f8"

# Verwachte output-hashes (PROVENANCE.md is leidend; dit is de ingebouwde eindcontrole).
EXPECT_DIFFQ_SHA256="d06a8ccdf3048d76442a680dd89fd0932837cd56b62a9d0564f7584bf57a9a68"
EXPECT_SAMPLERATE_SHA256="3d5bcd3b72cf45b9d447cd8b5903b3b62b32fe9405384d9388eecb197a4a78f6"

# Gepinde build-toolchain (zelfde lijn als de 2.3.0.6-payload: cython 3.2.8, setuptools 83).
PIN_CYTHON="3.2.8"
PIN_SETUPTOOLS="83.0.0"

# --- Python 3.12 vinden (build-interpreter; wordt niet gemuteerd) --------------
find_python312() {
  if [ -n "${PYTHON312:-}" ] && [ -x "${PYTHON312}" ]; then printf "%s\n" "${PYTHON312}"; return 0; fi
  local c
  for c in \
    "${HOME}/Library/Application Support/STEMwerk/python/bin/python3.12" \
    "$(command -v python3.12 || true)"
  do
    [ -n "${c}" ] && [ -x "${c}" ] && { printf "%s\n" "${c}"; return 0; }
  done
  return 1
}
PY312="$(find_python312)" || { echo "FOUT: geen python3.12 gevonden (zet PYTHON312)" >&2; exit 1; }
echo "build-python: ${PY312} ($("${PY312}" --version 2>&1))"

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

fetch() { # url dest expected_sha
  curl -fsSL --retry 3 -o "$2" "$1"
  local got; got="$(sha256_of "$2")"
  if [ "${got}" != "$3" ]; then
    echo "FOUT: sha256 mismatch voor $2: ${got} != $3" >&2; exit 1
  fi
}

# --- Geïsoleerde, gepinde build-omgeving --------------------------------------
TMPDIR="${WORK}" "${PY312}" -m venv "${WORK}/buildenv"
BENV="${WORK}/buildenv/bin/python"
"${BENV}" -m pip install --quiet --disable-pip-version-check \
  "cython==${PIN_CYTHON}" "setuptools==${PIN_SETUPTOOLS}"
mkdir -p "${WORK}/built" "${WORK}/final"

# Deterministische retag: entries in vaste volgorde met genormaliseerde timestamps kopieren,
# dist-info/WHEEL inhoudelijk aanpassen en RECORD volledig regenereren (anders faalt pip's
# RECORD-verificatie bij installatie). Output hangt zo alleen van de inhoud af.
retag_wheel() { # src dst new_tag
  "${BENV}" - "$1" "$2" "$3" <<'PYEOF'
import base64, hashlib, sys, zipfile
src, dst, new_tag = sys.argv[1], sys.argv[2], sys.argv[3]
EPOCH = (2026, 1, 1, 0, 0, 0)
def digest(data):
    h = hashlib.sha256(data).digest()
    return "sha256=" + base64.urlsafe_b64encode(h).rstrip(b"=").decode()
zin = zipfile.ZipFile(src)
infos = zin.infolist()
wheel_names = [i.filename for i in infos if i.filename.endswith(".dist-info/WHEEL")]
rec_names = [i.filename for i in infos if i.filename.endswith(".dist-info/RECORD")]
if len(wheel_names) != 1 or len(rec_names) != 1:
    sys.exit(f"WHEEL/RECORD niet eenduidig: {wheel_names} {rec_names}")
wname, rname = wheel_names[0], rec_names[0]
record_lines = []
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
    for info in infos:
        data = zin.read(info.filename)
        if info.filename == wname:
            lines = [l for l in data.decode().splitlines()
                     if l.strip() and not l.startswith("Tag:")]
            lines = ["Root-Is-Purelib: false" if l.startswith("Root-Is-Purelib:") else l
                     for l in lines]
            if not any(l.startswith("Root-Is-Purelib:") for l in lines):
                lines.append("Root-Is-Purelib: false")
            lines.append(f"Tag: {new_tag}")
            data = ("\n".join(lines) + "\n").encode()
        if info.filename == rname:
            continue  # RECORD schrijven we als laatste zelf
        record_lines.append(f"{info.filename},{digest(data)},{len(data)}")
        zi = zipfile.ZipInfo(info.filename, date_time=EPOCH)
        zi.compress_type = info.compress_type
        zi.external_attr = info.external_attr
        zout.writestr(zi, data)
    record_lines.append(f"{rname},,")
    zi = zipfile.ZipInfo(rname, date_time=EPOCH)
    zi.compress_type = zipfile.ZIP_DEFLATED
    zout.writestr(zi, ("\n".join(record_lines) + "\n").encode())
print(f"retagged {src} -> {dst} (Tag: {new_tag})")
PYEOF
}

# --- 1) diffq: cross-build sdist → x86_64 wheel, daarna retag ------------------
fetch "${DIFFQ_SDIST_URL}" "${WORK}/diffq-${DIFFQ_VERSION}.tar.gz" "${DIFFQ_SDIST_SHA256}"
# Zelf uitpakken naar een VAST pad: pip's eigen build-tmp is random en belandt via __FILE__
# in de gecompileerde .so (run-op-run verschillende bytes).
mkdir -p "${WORK}/src" && tar -xzf "${WORK}/diffq-${DIFFQ_VERSION}.tar.gz" -C "${WORK}/src"
( cd "${WORK}" && \
  TMPDIR="${WORK}" ARCHFLAGS="-arch x86_64" MACOSX_DEPLOYMENT_TARGET=11.0 \
  LDFLAGS="-Wl,-no_uuid -Wl,-S" \
  "${BENV}" -m pip wheel --no-deps --no-build-isolation \
    -w "${WORK}/built" "${WORK}/src/diffq-${DIFFQ_VERSION}" )

BUILT_DIFFQ="$(ls "${WORK}"/built/diffq-${DIFFQ_VERSION}-cp312-cp312-macosx_11_0_*.whl)"
# De compiler honoreert ARCHFLAGS (inhoud x86_64), de tag volgt de build-host (arm64) → retag.
retag_wheel "${BUILT_DIFFQ}" \
  "${WORK}/final/diffq-${DIFFQ_VERSION}-cp312-cp312-macosx_11_0_x86_64.whl" \
  "cp312-cp312-macosx_11_0_x86_64"

# Inhoudscontrole: de .so moet x86_64 zijn (D7-bewijsvoering).
( cd "${WORK}" && unzip -o -q "${WORK}"/final/diffq-*.whl -d inspect )
SO="$(find "${WORK}/inspect" -name '*.so' | head -1)"
file "${SO}" | grep -q "x86_64" || { echo "FOUT: diffq .so is geen x86_64" >&2; exit 1; }

# --- 2) samplerate: PyPI-wheel retaggen naar macosx_11_0_x86_64 ----------------
fetch "${SAMPLERATE_WHEEL_URL}" "${WORK}/samplerate-${SAMPLERATE_VERSION}-py2.py3-none-any.whl" "${SAMPLERATE_WHEEL_SHA256}"
retag_wheel "${WORK}/samplerate-${SAMPLERATE_VERSION}-py2.py3-none-any.whl" \
  "${WORK}/final/samplerate-${SAMPLERATE_VERSION}-py3-none-macosx_11_0_x86_64.whl" \
  "py3-none-macosx_11_0_x86_64"
( cd "${WORK}" && unzip -o -q "${WORK}"/final/samplerate-*.whl -d sr-inspect )
DYLIB="$(find "${WORK}/sr-inspect" -name '*.dylib' | head -1)"
file "${DYLIB}" | grep -q "x86_64" || { echo "FOUT: samplerate dylib is geen x86_64" >&2; exit 1; }

# --- 3) Plaatsing + eindcontrole -----------------------------------------------
cp "${WORK}"/final/diffq-${DIFFQ_VERSION}-cp312-cp312-macosx_11_0_x86_64.whl "${OUT_DIR}/"
cp "${WORK}"/final/samplerate-${SAMPLERATE_VERSION}-py3-none-macosx_11_0_x86_64.whl "${OUT_DIR}/"

ok=1
for pair in \
  "${OUT_DIR}/diffq-${DIFFQ_VERSION}-cp312-cp312-macosx_11_0_x86_64.whl:${EXPECT_DIFFQ_SHA256}" \
  "${OUT_DIR}/samplerate-${SAMPLERATE_VERSION}-py3-none-macosx_11_0_x86_64.whl:${EXPECT_SAMPLERATE_SHA256}"
do
  f="${pair%%:*}"; want="${pair##*:}"; got="$(sha256_of "${f}")"
  if [ "${got}" = "${want}" ]; then
    echo "OK  sha256 $(basename "${f}")  ${got}"
  else
    echo "MISMATCH $(basename "${f}"): ${got} != ${want}" >&2
    echo "  → toolchain-drift (clang/SDK/Cython)? Herbepaal en werk PROVENANCE.md bij." >&2
    ok=0
  fi
done
[ "${ok}" = 1 ] || exit 1
echo "klaar: ${OUT_DIR}"
