"""Linux S5b outer bootstrap integration tests using the pinned archive.

Set STEMWERK_TEST_PINNED_PYTHON_ARCHIVE to a separately verified download.
The CI Linux bootstrap job supplies it; no test downloads or edits a user root.
"""

from __future__ import annotations

import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import runpy
import shutil
import shlex
import signal
import ssl
import subprocess
import sys
import tarfile
import threading
import time

import pytest

REPO = Path(__file__).resolve().parents[1]
SRC = REPO / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(SRC))
from stemwerk_core import install_events, runtime_manifest  # noqa: E402

PIN = runtime_manifest.python_record("linux-x86_64")
ARCHIVE = os.environ.get("STEMWERK_TEST_PINNED_PYTHON_ARCHIVE")
pytestmark = pytest.mark.skipif(sys.platform != "linux", reason="Linux outer layer only")


@pytest.fixture(scope="session")
def pinned_archive():
    assert ARCHIVE, "STEMWERK_TEST_PINNED_PYTHON_ARCHIVE must name the verified pin"
    path = Path(ARCHIVE)
    assert path.stat().st_size == PIN.size
    assert hashlib.sha256(path.read_bytes()).hexdigest() == PIN.sha256
    return path


@pytest.fixture
def harness(tmp_path, pinned_archive):
    reaper = tmp_path / "reaper"
    (reaper / "_internal").mkdir(parents=True)
    shutil.copy2(REPO / "scripts/reaper/STEMwerk_Bootstrap_Linux.sh", reaper)
    shutil.copy2(REPO / "scripts/reaper/_internal/STEMwerk_Managed_Python_Linux.sh", reaper / "_internal")
    target_src = reaper / "vendor/stemwerk-core/src"
    shutil.copytree(SRC, target_src, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    curl = bin_dir / "curl"
    curl.write_text(
        "#!/bin/sh\n"
        "[ \"$1\" = -q ] || exit 41\n"
        "[ -z \"${HTTPS_PROXY:-}${https_proxy:-}${ALL_PROXY:-}${all_proxy:-}\" ] || exit 42\n"
        "while [ \"$#\" -gt 0 ]; do\n"
        "  case $1 in -o) output=$2; shift 2;; -D) headers=$2; shift 2;; *) shift;; esac\n"
        "done\n"
        "if [ \"${STEMWERK_TEST_NETWORK_FAIL:-}\" = 1 ]; then exit 7; fi\n"
        "if [ -n \"${STEMWERK_TEST_DELAY:-}\" ]; then sleep \"$STEMWERK_TEST_DELAY\"; fi\n"
        "if [ -n \"${STEMWERK_TEST_BARRIER:-}\" ]; then\n"
        "  : > \"$output.ready\"\n"
        "  while [ ! -f \"$STEMWERK_TEST_BARRIER.release\" ]; do sleep 0.05; done\n"
        "fi\n"
        "if [ -n \"${STEMWERK_TEST_REDIRECT_LOCATION:-}\" ]; then\n"
        "  printf 'HTTP/1.1 302 Found\\r\\nLocation: %s\\r\\n\\r\\n' \"$STEMWERK_TEST_REDIRECT_LOCATION\" > \"$headers\"\n"
        "  printf 302; exit 0\n"
        "fi\n"
        "cp \"$STEMWERK_TEST_ARCHIVE\" \"$output\"\n"
        "printf 'HTTP/1.1 200 OK\\r\\n\\r\\n' > \"$headers\"\n"
        "printf 200\n",
        encoding="ascii",
    )
    curl.chmod(0o755)
    env = {**os.environ, "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"], "STEMWERK_TEST_ARCHIVE": str(pinned_archive)}
    return reaper, tmp_path / "root", env


def run(harness, *args, archive=None, root=None, env=None):
    reaper, default_root, default_env = harness
    use_env = {**default_env, **(env or {})}
    if archive is not None:
        use_env["STEMWERK_TEST_ARCHIVE"] = str(archive)
    return subprocess.run(
        ["/bin/sh", str(reaper / "STEMwerk_Bootstrap_Linux.sh"), "--managed-python-bootstrap", "--root", str(root or default_root), "--", *(args or ("plan", "--module", "drum_kit"))],
        env=use_env, capture_output=True, text=True, timeout=120,
    )


def restricted_path(tmp_path):
    directory = tmp_path / "minimal-bin"
    directory.mkdir()
    for name in (
        "cat", "mkdir", "dirname", "tail", "od", "tr", "date", "uname",
        "tar", "gzip", "sha256sum", "realpath", "find", "stat", "id",
        "rm", "ln", "sleep", "sed", "wc", "cut", "cp",
    ):
        (directory / name).symlink_to(shutil.which(name))
    return directory


def operation(root):
    return max((root / "logs").iterdir(), key=lambda path: path.stat().st_mtime_ns)


def check_failure(root, code):
    matching = [path for path in (root / "logs").iterdir() if install_events.read_events(path)[-1].get("error_code") == code]
    assert matching
    op = matching[-1]
    events = install_events.read_events(op)
    assert events[-1]["state"] == "failed"
    assert events[-1]["error_code"] == code
    result = json.loads((op / "result.json").read_text())
    install_events.validate_result(result)
    assert result["exit_code"] == 2
    assert result["document"]["error"]["code"] == code
    assert not (root / "tmp" / op.name / "bootstrap").exists()


def test_fresh_and_verified_reuse(harness):
    _, root, _ = harness
    first = run(harness)
    assert first.returncode == 0, first.stderr
    assert json.loads(first.stdout)["kind"] == "stemwerk_module_install_plan"
    destination = root / "runtimes/python" / PIN.name
    inode = destination.stat().st_ino
    assert install_events.read_events(operation(root))[-1]["state"] == "done"
    assert (operation(root) / "bootstrap.outcome").read_text().strip() == "new"
    second = run(harness)
    assert second.returncode == 0, second.stderr
    assert destination.stat().st_ino == inode
    assert (operation(root) / "bootstrap.outcome").read_text().strip() == "reused"
    assert len(list((root / "logs").iterdir())) == 2
    assert all(not (path / "bootstrap").exists() for path in (root / "tmp").iterdir())


def test_manifest_and_platform_refusals(harness):
    reaper, root, env = harness
    manifest = reaper / "vendor/stemwerk-core/src/stemwerk_core/runtime-manifest.v1.tsv"
    original = manifest.read_bytes()
    manifest.write_bytes(original + b"bad\tline\n")
    result = run(harness)
    assert result.returncode == 2
    check_failure(root, "manifest_invalid")
    manifest.write_bytes(original)
    fake_bin = Path(env["PATH"].split(os.pathsep)[0])
    uname = fake_bin / "uname"
    uname.write_text("#!/bin/sh\ncase $1 in -s) echo Linux;; -m) echo aarch64;; esac\n", encoding="ascii")
    uname.chmod(0o755)
    result = run(harness)
    assert result.returncode == 2
    check_failure(root, "platform_unsupported")


def test_missing_downloader(harness, tmp_path):
    _, root, env = harness
    minimal = restricted_path(tmp_path)
    result = run(harness, env={"PATH": str(minimal)})
    assert result.returncode == 2
    check_failure(root, "download_prerequisite_unavailable")


def test_curl_ignores_conflicting_home_configuration(harness, tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    (home / ".curlrc").write_text("location\nproxy = http://127.0.0.1:9\n")
    result = run(harness, env={"HOME": str(home), "HTTPS_PROXY": "http://dummy:dummy@127.0.0.1:9"})
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["kind"] == "stemwerk_module_install_plan"


def test_curl_is_preferred_over_wget2(harness, tmp_path):
    _, root, env = harness
    fake_bin = Path(env["PATH"].split(os.pathsep)[0])
    marker = tmp_path / "wget2-invoked"
    wget = fake_bin / "wget"
    wget.write_text("#!/bin/sh\nprintf called > " + shlex.quote(str(marker)) + "\nprintf 'GNU Wget2 2.3.0\\n'\n")
    wget.chmod(0o755)
    result = run(harness)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["kind"] == "stemwerk_module_install_plan"
    assert (operation(root) / "bootstrap.outcome").read_text().strip() == "new"
    assert not marker.exists(), "wget2 was probed or used despite curl availability"


@pytest.mark.parametrize("version", ["GNU Wget2 2.3.0", "BusyBox v1.36.1"])
def test_unsupported_wget_is_refused_before_any_download(harness, tmp_path, version):
    _, root, _ = harness
    minimal = restricted_path(tmp_path)
    token = "s5b-wget2-dummy-" + tmp_path.name
    marker = tmp_path / "wget2-download-request"
    wget = minimal / "wget"
    wget.write_text(
        "#!/bin/sh\n"
        "if [ \"${1:-}\" = --no-config ] && [ \"${2:-}\" = --version ]; then printf '%s\\n' " + shlex.quote(version) + "; exit 0; fi\n"
        "printf '%s\\n' \"$STEMWERK_TEST_DUMMY_TOKEN\" > \"$STEMWERK_TEST_REQUEST_MARKER\"\n"
        "printf 'URL %s\\n' \"$STEMWERK_TEST_DUMMY_TOKEN\"\n"
        "exit 0\n"
    )
    wget.chmod(0o755)
    home = tmp_path / "home"
    home.mkdir()
    result = run(harness, env={"PATH": str(minimal), "HOME": str(home), "STEMWERK_TEST_DUMMY_TOKEN": token, "STEMWERK_TEST_REQUEST_MARKER": str(marker)})
    assert result.returncode == 2
    assert json.loads(result.stderr)["error"]["code"] == "download_prerequisite_unavailable"
    assert "curl or GNU Wget 1.x is required" in result.stderr
    check_failure(root, "download_prerequisite_unavailable")
    assert not marker.exists(), "wget2 made a download request"
    assert token not in result.stdout + result.stderr
    assert not any(token in file.read_text() for file in root.rglob("*") if file.is_file())
    assert not (root / "runtimes/python" / PIN.name).exists()


def test_wget_uses_exact_signed_redirect_and_ignores_home_config(harness, tmp_path):
    _, root, env = harness
    minimal = restricted_path(tmp_path)
    token = "s5b-query-" + tmp_path.name
    signed = f"https://release-assets.githubusercontent.com/example/asset?sig={token}%2Bb&expiry=123"
    requests = tmp_path / "wget-requests"
    wget = minimal / "wget"
    wget.write_text(
        "#!/bin/sh\n"
        "if [ \"${1:-}\" = --no-config ] && [ \"${2:-}\" = --version ]; then printf 'GNU Wget 1.25.0\\n'; exit 0; fi\n"
        "[ \"$1\" = --no-config ] || exit 41\n"
        "[ -z \"${HTTPS_PROXY:-}${https_proxy:-}${ALL_PROXY:-}${all_proxy:-}\" ] || exit 42\n"
        "netrc=0; hsts=0\n"
        "while [ \"$#\" -gt 0 ]; do\n"
        "  case $1 in --no-netrc) netrc=1; shift;; --no-hsts) hsts=1; shift;;"
        " -O) output=$2; shift 2;; *) url=$1; shift;; esac\n"
        "done\n"
        "[ \"$netrc:$hsts\" = 1:1 ] || exit 43\n"
        "printf '%s\\n' \"$url\" >> \"$STEMWERK_TEST_WGET_REQUESTS\"\n"
        "printf 'Progress: %s\\n' \"$url\"\n"
        "printf 'Request: %s\\n' \"$url\" >&2\n"
        "if [ \"$url\" = \"$STEMWERK_TEST_SIGNED_URL\" ]; then\n"
        "  cp \"$STEMWERK_TEST_ARCHIVE\" \"$output\"\n"
        "  printf '  HTTP/1.1 200 OK\\n' >&2\n"
        "elif [ \"$url\" = \"$STEMWERK_TEST_INITIAL_URL\" ]; then\n"
        "  printf '  HTTP/1.1 302 Found\\n  Location: %s\\nLocation: %s [following]\\n' \"$STEMWERK_TEST_SIGNED_URL\" \"$STEMWERK_TEST_SIGNED_URL\" >&2\n"
        "  exit 8\n"
        "else\n"
        "  printf 'wrong redirect target\\n' >&2; exit 9\n"
        "fi\n",
        encoding="ascii",
    )
    wget.chmod(0o755)
    home = tmp_path / "home"
    home.mkdir()
    (home / ".wgetrc").write_text("use_proxy = on\nhttps_proxy = http://127.0.0.1:9\n")
    result = run(harness, env={"PATH": str(minimal), "HOME": str(home), "HTTPS_PROXY": "http://dummy:dummy@127.0.0.1:9", "STEMWERK_TEST_SIGNED_URL": signed, "STEMWERK_TEST_INITIAL_URL": PIN.url, "STEMWERK_TEST_WGET_REQUESTS": str(requests)})
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["kind"] == "stemwerk_module_install_plan"
    assert (operation(root) / "bootstrap.outcome").read_text().strip() == "new"
    assert requests.read_text().splitlines() == [PIN.url, signed]
    assert token not in result.stdout + result.stderr
    assert not any(token in file.read_text() for file in (root / "logs").rglob("*") if file.is_file())


def live_session_processes(session_id):
    names = []
    for entry in Path("/proc").iterdir():
        if entry.name.isdigit():
            try:
                raw = (entry / "stat").read_text()
            except OSError:
                continue
            fields = raw[raw.rindex(")") + 2:].split()
            if fields[0] != "Z" and int(fields[3]) == session_id:
                names.append(raw[raw.index("(") + 1:raw.rindex(")")])
    return sorted(names)


def test_hangup_during_real_wget_download_is_a_contained_cancellation(harness, tmp_path):
    real_wget = shutil.which("wget")
    openssl = shutil.which("openssl")
    if not real_wget or not openssl:
        pytest.skip("needs real GNU Wget and openssl")
    version = subprocess.run([real_wget, "--no-config", "--version"], capture_output=True, text=True, timeout=10)
    if not version.stdout.startswith("GNU Wget 1."):
        pytest.skip("needs real GNU Wget 1.x")
    reaper, root, _ = harness
    certificate, key = tmp_path / "tls.pem", tmp_path / "tls.key"
    subprocess.run(
        [openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(certificate),
         "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"],
        check=True, capture_output=True, timeout=60,
    )
    token = "s5b-hup-query-" + tmp_path.name
    signed_target = f"/signed/example/asset?sig={token}%2Bb&expiry=123"
    first_target = "/first/" + PIN.url[len("https://github.com/"):]
    targets = []
    signed_seen = threading.Event()
    release = threading.Event()

    class Origin(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def do_GET(self):
            targets.append(self.path)
            if self.path == first_target:
                self.send_response(302)
                self.send_header("Location", f"https://release-assets.githubusercontent.com/example/asset?sig={token}%2Bb&expiry=123")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Length", str(PIN.size))
            self.end_headers()
            self.wfile.write(b"\0" * 1024)
            self.wfile.flush()
            signed_seen.set()
            release.wait(30)
            self.close_connection = True

    class Server(http.server.ThreadingHTTPServer):
        daemon_threads = True

        def handle_error(self, request, client_address):
            pass

    server = Server(("127.0.0.1", 0), Origin)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)
    server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = f"https://localhost:{server.server_address[1]}"
    minimal = restricted_path(tmp_path)
    # Maps approved names to the local origin and execs the real client in the same process.
    wget = minimal / "wget"
    wget.write_text(
        "#!/bin/sh\n"
        f"case ${{1:-}}:${{2:-}} in --no-config:--version) exec {shlex.quote(real_wget)} \"$@\" ;; esac\n"
        "count=$#\n"
        "while [ \"$count\" -gt 1 ]; do set -- \"$@\" \"$1\"; shift; count=$((count - 1)); done\n"
        "url=$1; shift\n"
        "case $url in\n"
        f"  https://github.com/*) url={origin}/first/${{url#https://github.com/}} ;;\n"
        f"  https://release-assets.githubusercontent.com/*) url={origin}/signed/${{url#https://release-assets.githubusercontent.com/}} ;;\n"
        "  *) exit 9 ;;\n"
        "esac\n"
        f"exec {shlex.quote(real_wget)} \"$@\" --ca-certificate={shlex.quote(str(certificate))} \"$url\"\n",
        encoding="ascii",
    )
    wget.chmod(0o755)
    home, working = tmp_path / "home", tmp_path / "working"
    home.mkdir()
    working.mkdir()
    (home / ".netrc").write_text("machine localhost login dummy_user password dummy_password\n")
    stdout_path, stderr_path = tmp_path / "stdout", tmp_path / "stderr"
    process = None
    try:
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            process = subprocess.Popen(
                ["/bin/sh", str(reaper / "STEMwerk_Bootstrap_Linux.sh"), "--managed-python-bootstrap", "--root", str(root), "--", "plan", "--module", "drum_kit"],
                env={"PATH": str(minimal), "HOME": str(home), "LANG": "C"}, cwd=working, stdout=stdout, stderr=stderr, start_new_session=True,
            )
        assert signed_seen.wait(30), stderr_path.read_text()
        os.killpg(process.pid, signal.SIGHUP)
        hangup_at = time.monotonic()
        try:
            returncode = process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            returncode = "did not exit within 10 seconds"
        exit_seconds = time.monotonic() - hangup_at
        # A surviving client would log its retry, with the query, once the connection ends.
        release.set()
        deadline = time.monotonic() + 6
        wget_log = working / "wget-log"
        while time.monotonic() < deadline and live_session_processes(process.pid):
            if wget_log.exists() and token in wget_log.read_text(errors="replace"):
                break
            time.sleep(0.1)
        observed = {
            "returncode": returncode,
            "live_processes": live_session_processes(process.pid),
            "working_directory": sorted(path.name for path in working.iterdir()),
            "files_with_query": sorted(
                str(path.relative_to(tmp_path)).replace(operation(root).name, "<op>")
                for path in tmp_path.rglob("*")
                if path.is_file() and not path.is_symlink() and token.encode() in path.read_bytes()
            ),
            # An observation about this run, not a parsing rule: the shell may print a job notice first.
            # check_failure below is the contract assertion; it reads the failed event and result.json.
            "stderr_last_line": (stderr_path.read_text().splitlines() or [""])[-1],
            "downloader_text_in_stderr": any(word in stderr_path.read_text() for word in ("wget", "HTTP/", "localhost", "githubusercontent")),
            "stdout": stdout_path.read_text(),
            "staging": sorted(path.parent.name.replace(operation(root).name, "<op>") for path in (root / "tmp").glob("*/bootstrap")),
            "runtimes": sorted(path.name for path in (root / "runtimes/python").iterdir()),
            "home": sorted(path.name for path in home.iterdir()),
        }
    finally:
        release.set()
        if process is not None:
            if live_session_processes(process.pid):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)
        server.shutdown()
        server.server_close()
    assert targets[:2] == [first_target, signed_target]
    assert observed == {
        "returncode": 2, "live_processes": [], "working_directory": [], "files_with_query": [],
        "stderr_last_line": json.dumps({"kind": "stemwerk_module_install_error", "schema_version": "1.0.0", "error": {"code": "cancelled", "message": "Bootstrap was interrupted", "module": None}}, separators=(",", ":")),
        "downloader_text_in_stderr": False, "stdout": "", "staging": [], "runtimes": [], "home": [".netrc"],
    }
    assert exit_seconds < 5
    check_failure(root, "cancelled")


def test_early_log_failures_report_stderr_without_claiming_result(harness):
    _, root, _ = harness
    root.mkdir()
    (root / "logs").write_text("not a directory")
    result = run(harness)
    assert result.returncode == 2
    assert json.loads(result.stderr)["error"]["code"] == "operation_log_unavailable"
    assert (root / "logs").read_text() == "not a directory"
    assert not list(root.rglob("result.json"))


def test_read_only_root_reports_early_failure(harness):
    if os.geteuid() == 0:
        pytest.skip("root can create a log directory despite directory mode")
    _, root, _ = harness
    root.mkdir(mode=0o700)
    root.chmod(0o500)
    try:
        result = run(harness)
        assert result.returncode == 2
        assert json.loads(result.stderr)["error"]["code"] == "operation_log_unavailable"
        assert not (root / "logs").exists()
    finally:
        root.chmod(0o700)


def test_private_root_under_sticky_tmp_and_shared_root_refusal(harness):
    _, root, _ = harness
    root.mkdir(mode=0o700)
    root.chmod(0o777)
    refused = run(harness)
    assert refused.returncode == 2
    assert json.loads(refused.stderr)["error"]["code"] == "root_not_private"
    assert not (root / "logs").exists()
    root.chmod(0o700)
    allowed = run(harness)
    assert allowed.returncode == 0, allowed.stderr


def test_missing_or_failing_find_stops_before_staged_python(harness, tmp_path):
    reaper, root, _ = harness
    minimal = restricted_path(tmp_path)
    (minimal / "curl").symlink_to(tmp_path / "bin/curl")
    (minimal / "find").unlink()
    missing = run(harness, env={"PATH": str(minimal)})
    assert missing.returncode == 2
    check_failure(root, "bootstrap_prerequisite_unavailable")
    marker = tmp_path / "staged-python-ran"
    helper = reaper / "vendor/stemwerk-core/src/linux_bootstrap_publish.py"
    helper.write_text("from pathlib import Path\nPath(" + repr(str(marker)) + ").write_text('ran')\n" + helper.read_text())
    (minimal / "find").write_text("#!/bin/sh\nexit 42\n")
    (minimal / "find").chmod(0o755)
    failed = run(harness, env={"PATH": str(minimal)})
    assert failed.returncode == 2
    check_failure(root, "archive_unsafe")
    assert not marker.exists()
    assert not (root / "runtimes/python" / PIN.name).exists()


def test_network_failure_and_cancel_leave_unrelated_content(harness):
    reaper, root, env = harness
    unrelated = root / "other-data"
    unrelated.mkdir(parents=True)
    (unrelated / "keep").write_text("keep")
    failed = run(harness, env={"STEMWERK_TEST_NETWORK_FAIL": "1"})
    assert failed.returncode == 2
    check_failure(root, "direct_https_failed")
    command = ["/bin/sh", str(reaper / "STEMwerk_Bootstrap_Linux.sh"), "--managed-python-bootstrap", "--root", str(root), "--", "plan", "--module", "drum_kit"]
    process = subprocess.Popen(command, env={**env, "STEMWERK_TEST_DELAY": "15"}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            operations = list((root / "logs").iterdir())
            active = [path for path in operations if (root / "tmp" / path.name / "bootstrap/owner").is_file()]
            if active:
                (active[0] / "cancel.request").touch()
                break
            time.sleep(0.05)
        else:
            pytest.fail("bootstrap did not create owner record")
        _, stderr = process.communicate(timeout=15)
        assert process.returncode == 2, stderr
        check_failure(root, "cancelled")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    assert (unrelated / "keep").read_text() == "keep"
    assert not (root / "runtimes/python" / PIN.name).exists()


@pytest.mark.parametrize("location", ["http://github.com/asset", "https://github.com.evil.example/asset"])
def test_redirect_policy_refuses_unsafe_destination(harness, location):
    _, root, _ = harness
    result = run(harness, env={"STEMWERK_TEST_REDIRECT_LOCATION": location})
    assert result.returncode == 2
    check_failure(root, "network_policy_refused")
    assert not (root / "runtimes/python" / PIN.name).exists()


@pytest.mark.parametrize(
    "damage,code",
    [
        ("truncate", "archive_size_mismatch"),
        ("tamper", "archive_sha256_mismatch"),
        ("badpin", "archive_sha256_mismatch"),
    ],
)
def test_bad_archive_never_publishes(harness, tmp_path, pinned_archive, damage, code):
    reaper, root, _ = harness
    damaged = tmp_path / "damaged.tar.gz"
    shutil.copyfile(pinned_archive, damaged)
    if damage == "badpin":
        manifest = reaper / "vendor/stemwerk-core/src/stemwerk_core/runtime-manifest.v1.tsv"
        manifest.write_text(manifest.read_text().replace(PIN.sha256, "0" * 64))
    else:
        with damaged.open("r+b") as handle:
            if damage == "truncate":
                handle.truncate(PIN.size - 1)
            else:
                handle.seek(100)
                byte = handle.read(1)
                handle.seek(100)
                handle.write(bytes([byte[0] ^ 1]))
    result = run(harness, archive=damaged)
    assert result.returncode == 2
    check_failure(root, code)
    assert not (root / "runtimes/python" / PIN.name).exists()


@pytest.mark.parametrize("member", ["python/../../escape", "python/bin/python3.12"])
def test_unsafe_archive_entries(harness, tmp_path, member):
    reaper, root, _ = harness
    archive = tmp_path / "unsafe.tar.gz"
    with tarfile.open(archive, "w:gz") as output:
        info = tarfile.TarInfo(member)
        if member.endswith("python3.12"):
            info.type = tarfile.SYMTYPE
            info.linkname = "/tmp/escaped"
        else:
            info.size = 1
            output.addfile(info, io.BytesIO(b"x"))
            info = None
        if info is not None:
            output.addfile(info)
    manifest = reaper / "vendor/stemwerk-core/src/stemwerk_core/runtime-manifest.v1.tsv"
    data = manifest.read_text()
    data = data.replace(str(PIN.size), str(archive.stat().st_size)).replace(PIN.sha256, hashlib.sha256(archive.read_bytes()).hexdigest())
    manifest.write_text(data)
    result = run(harness, archive=archive)
    assert result.returncode == 2
    check_failure(root, "archive_unsafe")
    assert not (tmp_path / "escape").exists()


def test_existing_destination_is_preserved(harness):
    _, root, _ = harness
    destination = root / "runtimes/python" / PIN.name
    destination.mkdir(parents=True)
    marker = destination / "unrelated"
    marker.write_text("keep")
    result = run(harness)
    assert result.returncode == 2
    check_failure(root, "runtime_conflict")
    assert marker.read_text() == "keep"


def test_forged_runtime_is_rejected_without_executing_it(harness, tmp_path):
    _, root, _ = harness
    destination = root / "runtimes/python" / PIN.name
    executable = destination / "bin/python3.12"
    executable.parent.mkdir(parents=True)
    marker = tmp_path / "forged-executed"
    report = json.dumps({
        "implementation": "cpython", "version": "3.12.16", "machine": "x86_64",
        "pointer_bits": 64, "prefix": str(destination), "isolated": 1,
    })
    executable.write_text(
        "#!/bin/sh\n"
        "printf ran > " + shlex.quote(str(marker)) + "\n"
        "if [ \"${3:-}\" = -c ]; then printf '%s\\n' " + shlex.quote(report) + "\n"
        "else printf '%s\\n' '{\"kind\":\"forged-core\"}'; fi\n"
    )
    executable.chmod(0o755)
    result = run(harness)
    assert result.returncode == 2
    check_failure(root, "runtime_conflict")
    assert not marker.exists(), "the published interpreter ran before payload comparison"
    assert executable.read_text().startswith("#!/bin/sh")


def test_runtime_identity_covers_executable_imports_extras_and_links(harness):
    _, root, _ = harness
    destination = root / "runtimes/python" / PIN.name
    first = run(harness)
    assert first.returncode == 0, first.stderr
    inode = destination.stat().st_ino
    original = run(harness)
    assert original.returncode == 0, original.stderr
    assert (operation(root) / "bootstrap.outcome").read_text().strip() == "reused"
    executable = destination / "bin/python3.12"
    importable = destination / "lib/python3.12/json/__init__.py"
    loadable = destination / "lib/libpython3.12.so.1.0"
    extra = destination / "lib/python3.12/extra_test.py"
    link = destination / "bin/python3"
    assert link.is_symlink() and importable.is_file() and loadable.is_file()
    for changed in ("executable", "importable", "loadable", "extra", "link"):
        if changed in ("executable", "importable", "loadable"):
            target = {"executable": executable, "importable": importable, "loadable": loadable}[changed]
            original_size = target.stat().st_size
            with target.open("ab") as handle:
                handle.write(b"\n# changed\n")
        elif changed == "extra":
            extra.write_text("VALUE = 1\n")
        else:
            original_target = os.readlink(link)
            link.unlink()
            link.symlink_to("python")
        try:
            result = run(harness)
            assert result.returncode == 2, (changed, result.stderr)
            check_failure(root, "runtime_conflict")
            assert destination.stat().st_ino == inode
        finally:
            if changed in ("executable", "importable", "loadable"):
                with target.open("r+b") as handle:
                    handle.truncate(original_size)
            elif changed == "extra":
                extra.unlink()
            else:
                link.unlink()
                link.symlink_to(original_target)
    final = run(harness)
    assert final.returncode == 0, final.stderr
    assert (operation(root) / "bootstrap.outcome").read_text().strip() == "reused"


def test_runtime_identity_rejects_same_size_byte_change(harness):
    _, root, _ = harness
    assert run(harness).returncode == 0
    destination = root / "runtimes/python" / PIN.name
    target = destination / "lib/python3.12/json/__init__.py"
    before = target.read_bytes()
    # Change a comment byte so a size-only comparator would accept a usable runtime.
    assert b"JSON (JavaScript Object Notation)" in before
    target.write_bytes(before.replace(b"JSON (JavaScript Object Notation)", b"JSON (JavaScript Object NotatioN)", 1))
    assert target.stat().st_size == len(before)
    inode = destination.stat().st_ino
    result = run(harness)
    assert result.returncode == 2, result.stderr
    check_failure(root, "runtime_conflict")
    assert destination.stat().st_ino == inode


def test_runtime_identity_rejects_mode_only_change(harness):
    _, root, _ = harness
    assert run(harness).returncode == 0
    target = root / "runtimes/python" / PIN.name / "lib/python3.12/json/__init__.py"
    before = target.read_bytes()
    old_mode = target.stat().st_mode & 0o777
    target.chmod(0o600 if old_mode != 0o600 else 0o400)
    assert target.read_bytes() == before
    assert target.stat().st_mode & 0o777 != old_mode
    result = run(harness)
    assert result.returncode == 2, result.stderr
    check_failure(root, "runtime_conflict")


def test_runtime_identity_rejects_group_writable_file(harness):
    reaper, root, _ = harness
    assert run(harness).returncode == 0
    target = root / "runtimes/python" / PIN.name / "lib/python3.12/json/__init__.py"
    target.chmod(target.stat().st_mode | 0o020)
    assert target.stat().st_mode & 0o020
    identity = runpy.run_path(str(reaper / "vendor/stemwerk-core/src/linux_bootstrap_publish.py"))["_tree_identity"]
    with pytest.raises(ValueError, match="writable or hard-linked"):
        identity(target.parent)
    result = run(harness)
    assert result.returncode == 2, result.stderr
    check_failure(root, "runtime_conflict")


def test_runtime_identity_rejects_hard_linked_file(harness, tmp_path):
    reaper, root, _ = harness
    assert run(harness).returncode == 0
    target = root / "runtimes/python" / PIN.name / "lib/python3.12/json/__init__.py"
    outside = tmp_path / "outside-hardlink"
    os.link(target, outside)
    assert target.stat().st_nlink == 2
    identity = runpy.run_path(str(reaper / "vendor/stemwerk-core/src/linux_bootstrap_publish.py"))["_tree_identity"]
    with pytest.raises(ValueError, match="writable or hard-linked"):
        identity(target.parent)
    result = run(harness)
    assert result.returncode == 2, result.stderr
    check_failure(root, "runtime_conflict")
    assert outside.samefile(target)


def test_reuse_refuses_unsafe_nonsticky_ancestor(harness):
    _, root, _ = harness
    assert run(harness).returncode == 0
    destination = root / "runtimes/python" / PIN.name
    inode = destination.stat().st_ino
    ancestor = root.parent
    original_mode = ancestor.stat().st_mode & 0o7777
    ancestor.chmod(0o777)
    try:
        assert not ancestor.stat().st_mode & 0o1000
        result = run(harness)
        assert result.returncode == 2, result.stderr
        assert json.loads(result.stderr)["error"]["code"] == "root_not_private"
        assert len(list((root / "logs").iterdir())) == 1
        assert destination.stat().st_ino == inode
    finally:
        ancestor.chmod(original_mode)


def test_concurrent_bootstraps_share_one_verified_destination(harness):
    reaper, root, env = harness
    command = ["/bin/sh", str(reaper / "STEMwerk_Bootstrap_Linux.sh"), "--managed-python-bootstrap", "--root", str(root), "--", "plan", "--module", "drum_kit"]
    barrier = root.parent / "publication-barrier"
    both_env = {**env, "STEMWERK_TEST_BARRIER": str(barrier)}
    one = subprocess.Popen(command, env=both_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    two = subprocess.Popen(command, env=both_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            ready = list((root / "tmp").glob("*/bootstrap/*.ready")) if (root / "tmp").exists() else []
            if len(ready) == 2:
                break
            time.sleep(0.05)
        else:
            pytest.fail("the two bootstraps did not overlap at the download barrier")
        barrier.with_suffix(".release").touch()
        first = one.communicate(timeout=120)
        second = two.communicate(timeout=120)
    finally:
        for process in (one, two):
            if process.poll() is None:
                process.kill()
                process.wait()
    assert one.returncode == two.returncode == 0, (first[1], second[1])
    assert json.loads(first[0])["kind"] == "stemwerk_module_install_plan"
    assert json.loads(second[0])["kind"] == "stemwerk_module_install_plan"
    assert (root / "runtimes/python" / PIN.name / "bin/python3.12").is_file()
    assert len(list((root / "logs").iterdir())) == 2
    assert sorted((path / "bootstrap.outcome").read_text().strip() for path in (root / "logs").iterdir()) == ["new", "reused"]
    assert all(not (path / "bootstrap").exists() for path in (root / "tmp").iterdir())


def test_overlapping_eexist_rejects_forged_winner_before_execution(harness, tmp_path):
    reaper, root, env = harness
    destination = root / "runtimes/python" / PIN.name
    executable = destination / "bin/python3.12"
    executable.parent.mkdir(parents=True)
    marker = tmp_path / "forged-executed"
    executable.write_text("#!/bin/sh\nprintf ran > " + shlex.quote(str(marker)) + "\nexit 0\n")
    executable.chmod(0o755)
    original = executable.read_bytes()
    inode = destination.stat().st_ino

    # This copy-only hook parks both processes inside the EEXIST handler. Both
    # live stagings then exist when the production comparison is evaluated.
    helper = reaper / "vendor/stemwerk-core/src/linux_bootstrap_publish.py"
    source = helper.read_text()
    needle = "        except asset_materialization.MaterializationError as exc:\n"
    hook = (
        "        except asset_materialization.MaterializationError as exc:\n"
        "            import time\n"
        "            barrier = Path(os.environ['STEMWERK_TEST_PUBLISH_BARRIER'])\n"
        "            (barrier.parent / (barrier.name + '.' + str(os.getpid()))).touch()\n"
        "            deadline = time.monotonic() + 30\n"
        "            while not barrier.exists() and time.monotonic() < deadline:\n"
        "                time.sleep(0.02)\n"
        "            if not barrier.exists():\n"
        "                raise RuntimeError('publication barrier timed out')\n"
    )
    assert source.count(needle) == 1
    helper.write_text(source.replace(needle, hook, 1))

    command = ["/bin/sh", str(reaper / "STEMwerk_Bootstrap_Linux.sh"), "--managed-python-bootstrap", "--root", str(root), "--", "plan", "--module", "drum_kit"]
    barrier = tmp_path / "eexist-release"
    both_env = {**env, "STEMWERK_TEST_PUBLISH_BARRIER": str(barrier)}
    processes = [subprocess.Popen(command, env=both_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(2)]
    try:
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            ready = list(tmp_path.glob("eexist-release.*"))
            stagings = list((root / "tmp").glob("*/bootstrap")) if (root / "tmp").exists() else []
            if len(ready) == 2 and len(stagings) == 2:
                break
            if any(process.poll() is not None for process in processes):
                pytest.fail("a bootstrap exited before both reached EEXIST")
            time.sleep(0.05)
        else:
            pytest.fail("both bootstraps did not reach the EEXIST branch with live staging")
        # Keep a second bootstrap directory visible until both handlers finish;
        # this makes the review's live-staging-count mutant deterministic.
        (root / "tmp" / "overlap-observer" / "bootstrap").mkdir(parents=True)
        barrier.touch()
        outputs = [process.communicate(timeout=120) for process in processes]
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait()
    assert not marker.exists(), "forged winner executed before EEXIST comparison"
    assert destination.stat().st_ino == inode
    assert executable.read_bytes() == original
    assert all(process.returncode == 2 for process in processes), outputs
    assert all("runtime_conflict" in stderr for _, stderr in outputs), outputs
    assert all(install_events.read_events(path)[-1].get("error_code") == "runtime_conflict" for path in (root / "logs").iterdir())
