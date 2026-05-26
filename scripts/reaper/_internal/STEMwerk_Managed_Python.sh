STEMWERK_MANAGED_PYTHON_VERSION="3.12.13"
STEMWERK_MANAGED_PYTHON_RELEASE="20260408"

managed_log() {
  if command -v log_step >/dev/null 2>&1; then
    log_step "$*"
  elif command -v log >/dev/null 2>&1; then
    log "$*"
  fi
}

managed_python_init_state() {
  MANAGED_PYTHON_ENABLED="yes"
  MANAGED_PYTHON_STATUS="missing"
  MANAGED_PYTHON_VERSION="${STEMWERK_MANAGED_PYTHON_VERSION}"
  MANAGED_PYTHON_RELEASE="${STEMWERK_MANAGED_PYTHON_RELEASE}"
  MANAGED_PYTHON_PLATFORM=""
  MANAGED_PYTHON_ARCH=""
  MANAGED_PYTHON_URL=""
  MANAGED_PYTHON_SHA256=""
  MANAGED_PYTHON_SHA256_OK="no"
  MANAGED_PYTHON_PATH=""
  MANAGED_PYTHON_ERROR=""
  MANAGED_PYTHON_REPLACED="no"
  MANAGED_PYTHON_ROLLBACK="no"
  SYSTEM_PYTHON_PATH=""
  SYSTEM_PYTHON_VERSION=""
  SYSTEM_PYTHON_USED="no"
}

managed_python_detect_platform() {
  _os="$(uname -s 2>/dev/null || printf unknown)"
  _arch="$(uname -m 2>/dev/null || printf unknown)"
  MANAGED_PYTHON_ARCH="${_arch}"
  case "${_os}:${_arch}" in
    Linux:x86_64|Linux:amd64)
      MANAGED_PYTHON_PLATFORM="linux"
      MANAGED_PYTHON_ARCH="x86_64"
      if ldd --version 2>&1 | grep -qi musl; then
        MANAGED_PYTHON_ERROR="unsupported_platform"
        return 1
      fi
      if ! { getconf GNU_LIBC_VERSION >/dev/null 2>&1 || ldd --version 2>&1 | grep -qi "glibc\\|GNU libc"; }; then
        MANAGED_PYTHON_ERROR="unsupported_platform"
        return 1
      fi
      MANAGED_PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260408/cpython-3.12.13%2B20260408-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz"
      MANAGED_PYTHON_SHA256="ddd48f521f79395d9b8b094d34a86d7ec86772ab66c96b0de65a3b561ea7cf10"
      return 0
      ;;
    Darwin:x86_64)
      MANAGED_PYTHON_PLATFORM="macos"
      MANAGED_PYTHON_ARCH="x86_64"
      MANAGED_PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260408/cpython-3.12.13%2B20260408-x86_64-apple-darwin-install_only_stripped.tar.gz"
      MANAGED_PYTHON_SHA256="1fee0596ba791fd83c33babf2ae8e00b0a1056b957955f2a34f7178ca8b80525"
      return 0
      ;;
    Darwin:arm64|Darwin:aarch64)
      MANAGED_PYTHON_PLATFORM="macos"
      MANAGED_PYTHON_ARCH="arm64"
      MANAGED_PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260408/cpython-3.12.13%2B20260408-aarch64-apple-darwin-install_only_stripped.tar.gz"
      MANAGED_PYTHON_SHA256="ac167e74961316ceabdbe4839f19aa6000c592b08e5a1fab4646cb225ede13d5"
      return 0
      ;;
  esac
  MANAGED_PYTHON_ERROR="unsupported_platform"
  return 1
}

managed_python_downloader() {
  if command -v curl >/dev/null 2>&1; then
    printf "curl\n"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    printf "wget\n"
    return 0
  fi
  return 1
}

managed_python_sha256_file() {
  _file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${_file}" | awk 'NR==1 { print $1; exit }'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${_file}" | awk 'NR==1 { print $1; exit }'
    return 0
  fi
  return 1
}

managed_python_archive_safe() {
  _archive="$1"
  tar -tzf "${_archive}" 2>/dev/null | while IFS= read -r _entry; do
    case "${_entry}" in
      ""|/*|../*|*/../*|*/..|..|*\\*)
        exit 1
        ;;
    esac
  done
}

managed_python_download() {
  _url="$1"
  _out="$2"
  _tool="$(managed_python_downloader || true)"
  if [ -z "${_tool}" ]; then
    MANAGED_PYTHON_ERROR="download_tool_missing"
    return 1
  fi
  case "${_tool}" in
    curl)
      curl -L --fail --show-error --output "${_out}.part" "${_url}" >> "${LOG_FILE}" 2>&1 || return 1
      ;;
    wget)
      wget -O "${_out}.part" "${_url}" >> "${LOG_FILE}" 2>&1 || return 1
      ;;
  esac
  mv "${_out}.part" "${_out}" || return 1
}

managed_python_exact_version() {
  _py="$1"
  [ -x "${_py}" ] || return 1
  _version="$("${_py}" -c 'import platform; print(platform.python_version())' 2>/dev/null || true)"
  [ "${_version}" = "${STEMWERK_MANAGED_PYTHON_VERSION}" ]
}

managed_python_validate_dir() {
  _dir="$1"
  _py=""
  for _candidate in \
    "${_dir}/bin/python3.12" \
    "${_dir}/bin/python3.11" \
    "${_dir}/bin/python3.10" \
    "${_dir}/bin/python3" \
    "${_dir}/python3.12" \
    "${_dir}/python3.11" \
    "${_dir}/python3.10" \
    "${_dir}/python3"
  do
    if [ -x "${_candidate}" ]; then
      _py="${_candidate}"
      break
    fi
  done
  if [ -z "${_py}" ]; then
    MANAGED_PYTHON_ERROR="python_executable_missing"
    return 1
  fi
  if ! managed_python_exact_version "${_py}"; then
    MANAGED_PYTHON_ERROR="python_validation_failed"
    return 1
  fi
  return 0
}

managed_python_restore_previous() {
  if [ -d "${RUNTIME_BASE}/python.prev" ]; then
    rm -rf "${RUNTIME_BASE}/python"
    if mv "${RUNTIME_BASE}/python.prev" "${RUNTIME_BASE}/python"; then
      MANAGED_PYTHON_ROLLBACK="yes"
      managed_log "Restored previous STEMwerk-managed Python runtime."
      return 0
    fi
  fi
  MANAGED_PYTHON_ROLLBACK="failed"
  return 1
}

managed_python_commit_next() {
  if ! managed_python_validate_dir "${RUNTIME_BASE}/python.next"; then
    rm -rf "${RUNTIME_BASE}/python.next"
    return 1
  fi

  rm -rf "${RUNTIME_BASE}/python.prev"
  if [ -d "${RUNTIME_BASE}/python" ]; then
    if ! mv "${RUNTIME_BASE}/python" "${RUNTIME_BASE}/python.prev"; then
      MANAGED_PYTHON_ERROR="backup_existing_failed"
      return 1
    fi
    MANAGED_PYTHON_REPLACED="yes"
  else
    MANAGED_PYTHON_REPLACED="no"
  fi

  if ! mv "${RUNTIME_BASE}/python.next" "${RUNTIME_BASE}/python"; then
    MANAGED_PYTHON_ERROR="install_move_failed"
    managed_python_restore_previous
    return 1
  fi

  if ! managed_python_validate_dir "${RUNTIME_BASE}/python"; then
    managed_python_restore_previous
    return 1
  fi

  rm -rf "${RUNTIME_BASE}/python.prev"
  MANAGED_PYTHON_PATH="${RUNTIME_BASE}/python/bin/python3"
  return 0
}

managed_python_install_archive() {
  _archive="$1"
  rm -rf "${RUNTIME_BASE}/python.tmp" "${RUNTIME_BASE}/python.next"
  mkdir -p "${RUNTIME_BASE}/python.tmp" || return 1
  if ! managed_python_archive_safe "${_archive}"; then
    MANAGED_PYTHON_ERROR="archive_path_traversal"
    rm -rf "${RUNTIME_BASE}/python.tmp"
    return 1
  fi
  tar -xzf "${_archive}" -C "${RUNTIME_BASE}/python.tmp" >> "${LOG_FILE}" 2>&1 || {
    MANAGED_PYTHON_ERROR="extract_failed"
    rm -rf "${RUNTIME_BASE}/python.tmp"
    return 1
  }
  if [ -x "${RUNTIME_BASE}/python.tmp/python/bin/python3" ]; then
    rm -rf "${RUNTIME_BASE}/python.next"
    mv "${RUNTIME_BASE}/python.tmp/python" "${RUNTIME_BASE}/python.next" || return 1
    rm -rf "${RUNTIME_BASE}/python.tmp"
  elif [ -x "${RUNTIME_BASE}/python.tmp/bin/python3" ]; then
    rm -rf "${RUNTIME_BASE}/python.next"
    mv "${RUNTIME_BASE}/python.tmp" "${RUNTIME_BASE}/python.next" || return 1
  else
    MANAGED_PYTHON_ERROR="python_executable_missing"
    rm -rf "${RUNTIME_BASE}/python.tmp" "${RUNTIME_BASE}/python.next"
    return 1
  fi
  managed_python_commit_next
}

install_managed_python_runtime() {
  managed_log "Installing STEMwerk-managed Python runtime..."
  managed_log "Attempting STEMwerk-managed Python runtime acquisition"
  for src in \
    "${STEMWERK_MANAGED_PYTHON_SOURCE:-}" \
    "${SCRIPT_DIR}/python" \
    "${SCRIPT_DIR}/runtime/python" \
    "${SCRIPT_DIR}/_runtime/python" \
    "${SCRIPT_DIR}/../runtime/python"
  do
    if [ -n "${src}" ] && [ -d "${src}" ]; then
      managed_log "Found local managed Python source: ${src}"
      rm -rf "${RUNTIME_BASE}/python.tmp"
      mkdir -p "${RUNTIME_BASE}/python.tmp" || return 1
      if cp -R "${src}/." "${RUNTIME_BASE}/python.tmp/" >> "${LOG_FILE}" 2>&1; then
        if managed_python_validate_dir "${RUNTIME_BASE}/python.tmp"; then
          rm -rf "${RUNTIME_BASE}/python.next"
          mv "${RUNTIME_BASE}/python.tmp" "${RUNTIME_BASE}/python.next" || return 1
          if ! managed_python_commit_next; then
            MANAGED_PYTHON_STATUS="failed"
            managed_log "STEMwerk could not install its managed Python runtime: ${MANAGED_PYTHON_ERROR:-install_failed}."
            return 1
          fi
          MANAGED_PYTHON_STATUS="installed"
          MANAGED_PYTHON_SHA256_OK="not_applicable"
          MANAGED_PYTHON_PATH="${RUNTIME_BASE}/python/bin/python3"
          managed_log "Installed pre-staged STEMwerk-managed Python runtime under ${RUNTIME_BASE}/python"
          return 0
        fi
      fi
      rm -rf "${RUNTIME_BASE}/python.tmp"
    fi
  done

  if ! managed_python_detect_platform; then
    MANAGED_PYTHON_STATUS="failed"
    managed_log "STEMwerk managed Python is not available for this platform yet."
    return 1
  fi

  mkdir -p "${RUNTIME_BASE}/state/downloads" || return 1
  _archive="${RUNTIME_BASE}/state/downloads/stemwerk-python-${MANAGED_PYTHON_PLATFORM}-${MANAGED_PYTHON_ARCH}-${MANAGED_PYTHON_VERSION}-${MANAGED_PYTHON_RELEASE}.tar.gz"
  if [ ! -f "${_archive}" ]; then
    managed_log "Downloading STEMwerk-managed Python runtime: ${MANAGED_PYTHON_URL}"
    if ! managed_python_download "${MANAGED_PYTHON_URL}" "${_archive}"; then
      MANAGED_PYTHON_STATUS="failed"
      MANAGED_PYTHON_ERROR="${MANAGED_PYTHON_ERROR:-download_failed}"
      managed_log "STEMwerk could not download its managed Python runtime. Check your internet connection or use a bundled/offline installer."
      return 1
    fi
  fi

  _actual="$(managed_python_sha256_file "${_archive}" || true)"
  if [ "${_actual}" != "${MANAGED_PYTHON_SHA256}" ]; then
    MANAGED_PYTHON_STATUS="failed"
    MANAGED_PYTHON_SHA256_OK="no"
    MANAGED_PYTHON_ERROR="sha256_mismatch"
    managed_log "Managed Python download failed verification and was not installed."
    rm -f "${_archive}"
    return 1
  fi
  MANAGED_PYTHON_SHA256_OK="yes"

  if ! managed_python_install_archive "${_archive}"; then
    MANAGED_PYTHON_STATUS="failed"
    managed_log "STEMwerk could not install its managed Python runtime: ${MANAGED_PYTHON_ERROR:-install_failed}."
    return 1
  fi

  MANAGED_PYTHON_STATUS="installed"
  managed_log "Verifying managed Python runtime..."
  managed_log "Installed STEMwerk-managed Python runtime under ${RUNTIME_BASE}/python"
  return 0
}
