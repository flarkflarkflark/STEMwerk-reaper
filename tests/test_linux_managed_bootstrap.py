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
import uuid

import pytest

REPO = Path(__file__).resolve().parents[1]
SRC = REPO / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(SRC))
from stemwerk_core import install_bootstrap, install_events, install_lock, runtime_manifest  # noqa: E402

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
        "setsid", "mkfifo", "sync", "readlink",
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


def check_cancelled(root):
    """The S8 terminal outcome (owner decision C): the terminal event is the
    existing v1 ``failed`` state with error_code ``cancelled``; result.json
    with error.code ``cancelled`` is the authority for the outcome."""
    def is_cancelled(path):
        events = install_events.read_events(path)
        last = events[-1]
        return last.get("state") == "failed" and last.get("error_code") == "cancelled"
    matching = [path for path in (root / "logs").iterdir() if is_cancelled(path)]
    assert matching
    op = matching[-1]
    events = install_events.read_events(op)
    assert events[-1]["state"] == "failed"
    assert events[-1]["error_code"] == "cancelled"
    for event in events:
        install_events.validate_event(event)
    result = json.loads((op / "result.json").read_text())
    install_events.validate_result(result)
    assert result["exit_code"] == 2
    assert result["document"]["error"]["code"] == "cancelled"
    assert not (root / "tmp" / op.name / "bootstrap").exists()
    return op


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
        stage_group = next(root.glob("tmp/*/bootstrap/group"))  # the worker group is in its own session
        recorded_group = install_bootstrap.parse_group(stage_group.read_bytes())["pgid"]
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
        "stderr_last_line": json.dumps({"kind": "stemwerk_module_install_error", "schema_version": "1.0.0", "operation": "install", "phase": "bootstrap", "error": {"code": "cancelled", "action": "Start a new operation", "detail": "Bootstrap was interrupted", "remains": {"staging_state": "removed", "retained": []}}}, separators=(",", ":")),
        "downloader_text_in_stderr": False, "stdout": "", "staging": [], "runtimes": [], "home": [".netrc"],
    }
    assert exit_seconds < 5
    with pytest.raises(ProcessLookupError):
        os.killpg(recorded_group, 0)  # the wget in the worker group is gone too, not only the controller's session
    check_cancelled(root)


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
        check_cancelled(root)
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


# --- S8: caller-chosen operation id and marker-before-work cancellation ---------


def bootstrap_command(reaper, root, *extra, core_args=("plan", "--module", "drum_kit")):
    return [
        "/bin/sh", str(reaper / "STEMwerk_Bootstrap_Linux.sh"),
        "--managed-python-bootstrap", "--root", str(root), *extra, "--", *core_args,
    ]


def test_operation_id_argument_is_validated(harness):
    reaper, root, env = harness
    for bad in ("NOT-A-UUID", str(uuid.uuid4()).upper(), str(uuid.uuid4()) + "0"):
        result = subprocess.run(
            bootstrap_command(reaper, root, "--operation-id", bad),
            env=env, capture_output=True, text=True, timeout=60,
        )
        assert result.returncode == 2
        assert "operation_id_invalid" in result.stderr
    assert not (root / "logs").exists() or not list((root / "logs").iterdir())


def test_a_reused_operation_id_is_refused(harness):
    reaper, root, env = harness
    op = str(uuid.uuid4())
    (root / "logs" / op).mkdir(parents=True)
    result = subprocess.run(
        bootstrap_command(reaper, root, "--operation-id", op),
        env=env, capture_output=True, text=True, timeout=60,
    )
    assert result.returncode == 2
    assert "operation_log_unavailable" in result.stderr


@pytest.mark.parametrize("form", ["file", "directory", "dangling_symlink"])
def test_a_marker_placed_as_soon_as_the_operation_exists_cancels_before_work(harness, form):
    reaper, root, env = harness
    op = str(uuid.uuid4())
    process = subprocess.Popen(
        bootstrap_command(reaper, root, "--operation-id", op),
        env={**env, "STEMWERK_TEST_DELAY": "15"},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    try:
        op_dir = root / "logs" / op
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not (op_dir / "events.ndjson").is_file():
            time.sleep(0.02)
        assert (op_dir / "events.ndjson").is_file(), "the bootstrap did not take the caller's operation id"
        marker_at = time.monotonic()
        marker = op_dir / "cancel.request"
        if form == "directory":
            marker.mkdir()
        elif form == "dangling_symlink":
            os.symlink(op_dir / "no-such-target", marker)
        else:
            marker.touch()
        _, stderr = process.communicate(timeout=20)
        detected = time.monotonic() - marker_at
        assert process.returncode == 2, stderr
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    assert detected < 5
    finished = check_cancelled(root)
    assert finished.name == op
    assert os.path.lexists(op_dir / "cancel.request")  # the outer layer never removes it
    assert not (root / "runtimes/python" / PIN.name).exists()
    # The retry is a new operation id; the old marker is not its concern.
    retry = run(harness)
    assert retry.returncode == 0, retry.stderr


def _slow_cp_wrapper(env):
    """A ``cp`` that sleeps first, keeping the archive staging wait alive."""
    bin_dir = Path(env["PATH"].split(os.pathsep)[0])
    wrapper = bin_dir / "cp"
    wrapper.write_text(
        "#!/bin/sh\nsleep 4\nexec " + shlex.quote(shutil.which("cp")) + ' "$@"\n',
        encoding="ascii",
    )
    wrapper.chmod(0o755)
    return wrapper


def test_an_unsearchable_operation_directory_stops_conservatively(harness, pinned_archive):
    """Sol's EACCES case (owner decision a): while work is active the marker
    lookup fails with EACCES. Only ENOENT may mean absent, so the bootstrap
    must stop conservatively at once and record the failed check — before
    managed Python exists, as an ordinary user, through the real entry."""
    reaper, root, env = harness
    _slow_cp_wrapper(env)
    op = str(uuid.uuid4())
    process = subprocess.Popen(
        bootstrap_command(reaper, root, "--operation-id", op, "--archive", str(pinned_archive)),
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    op_dir = root / "logs" / op
    stage = root / "tmp" / op / "bootstrap"
    try:
        deadline = time.monotonic() + 20
        while not (stage / "owner").is_file() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert (stage / "owner").is_file(), "the bootstrap did not reach the archive staging wait"
        time.sleep(0.3)  # the slowed copy is now genuinely in flight
        op_dir.chmod(0)
        denied_at = time.monotonic()
        # The next cancel_check poll (0.25 s) must stop the process while the
        # directory is still denied; the old code kept working for seconds.
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pytest.fail("the bootstrap kept running with an unanswerable marker lookup")
        stopped_in = time.monotonic() - denied_at
        assert process.returncode == 2
    finally:
        op_dir.chmod(0o700)
        if process.poll() is None:
            process.kill()
            process.wait()
    _, stderr = process.communicate()
    assert stopped_in < 2  # the local detection limit, measured from the denial
    assert '"code":"cancelled"' in stderr
    assert "not searchable" in stderr  # the failed check is recorded, not trusted
    assert not (root / "tmp" / op / "bootstrap").exists()  # staging was cleaned
    assert not (root / "runtimes/python" / PIN.name).exists()
    # Case A (the outer layer owns this directory, G1): it restored mode 700 on
    # that one directory and wrote exactly one terminal failed event and one
    # result.json, with the failed lookup's errno as a detail field.
    assert (op_dir.stat().st_mode & 0o777) == 0o700
    events = install_events.read_events(op_dir)
    for event in events:
        install_events.validate_event(event)
    terminal = [event for event in events if event["state"] == "failed"]
    assert len(terminal) == 1 and terminal[0] is events[-1]
    assert terminal[0]["error_code"] == "cancelled"
    result = json.loads((op_dir / "result.json").read_text())
    install_events.validate_result(result)
    assert result["exit_code"] == 2
    error = result["document"]["error"]
    assert error["code"] == "cancelled"
    assert error["cancel"]["cancel_reason"] == "check_failed"
    assert error["cancel"]["cancel_check_error"].startswith("EACCES: ")
    assert error["cancel"]["operation_directory_mode_restored"] is True
    assert error["remains"]["staging_state"] == "removed"
    assert json.loads(stderr.strip().splitlines()[-1])["error"]["cancel"] == error["cancel"]


def test_a_marker_symlink_is_probed_without_following(harness, tmp_path):
    """The marker probe is lstat-only (owner decision a): a symlink whose
    target sits in an unsearchable directory still counts as present. An
    implementation that followed the link would get EACCES and stop with a
    failed-check detail instead of honouring the request."""
    reaper, root, env = harness
    _slow_cp_wrapper(env)
    denied = tmp_path / "denied"
    (denied / "inner").mkdir(parents=True)
    op = str(uuid.uuid4())
    process = subprocess.Popen(
        bootstrap_command(reaper, root, "--operation-id", op, "--archive", env["STEMWERK_TEST_ARCHIVE"]),
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    op_dir = root / "logs" / op
    stage = root / "tmp" / op / "bootstrap"
    try:
        deadline = time.monotonic() + 20
        while not (stage / "owner").is_file() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert (stage / "owner").is_file(), "the bootstrap did not reach the archive staging wait"
        time.sleep(0.3)  # the slowed copy is now genuinely in flight
        denied.chmod(0)  # the target is unreachable; lstat of the link is not
        os.symlink(denied / "inner" / "target", op_dir / "cancel.request")
        _, stderr = process.communicate(timeout=20)
        assert process.returncode == 2, stderr
    finally:
        denied.chmod(0o700)
        if process.poll() is None:
            process.kill()
            process.wait()
    assert "Bootstrap cancellation was requested" in stderr
    assert "not searchable" not in stderr
    finished = check_cancelled(root)
    assert finished.name == op


def test_a_fifo_marker_is_never_opened_or_read(harness):
    """Only the marker's existence matters (owner decision a). A FIFO marker
    blocks any implementation that opens or reads it; the cancellation must
    complete promptly regardless."""
    reaper, root, env = harness
    _slow_cp_wrapper(env)
    op = str(uuid.uuid4())
    process = subprocess.Popen(
        bootstrap_command(reaper, root, "--operation-id", op, "--archive", env["STEMWERK_TEST_ARCHIVE"]),
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    try:
        op_dir = root / "logs" / op
        stage = root / "tmp" / op / "bootstrap"
        deadline = time.monotonic() + 20
        while not (stage / "owner").is_file() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert (stage / "owner").is_file(), "the bootstrap did not reach the archive staging wait"
        time.sleep(0.3)  # the slowed copy is now genuinely in flight
        marker_at = time.monotonic()
        os.mkfifo(op_dir / "cancel.request")
        _, stderr = process.communicate(timeout=20)
        detected = time.monotonic() - marker_at
        assert process.returncode == 2, stderr
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    assert detected < 5
    finished = check_cancelled(root)
    assert finished.name == op


def _start_and_wait_for_staging(harness, env, pinned_archive, tmp_path):
    reaper, root, _ = harness
    op = str(uuid.uuid4())
    stdout = open(tmp_path / "stdout.txt", "w+")
    stderr = open(tmp_path / "stderr.txt", "w+")
    process = subprocess.Popen(
        bootstrap_command(reaper, root, "--operation-id", op, "--archive", str(pinned_archive)),
        env=env, stdout=stdout, stderr=stderr, text=True,
    )
    stage = root / "tmp" / op / "bootstrap"
    deadline = time.monotonic() + 20
    while not (stage / "owner").is_file() and time.monotonic() < deadline:
        time.sleep(0.02)
    assert (stage / "owner").is_file(), "the bootstrap did not reach the archive staging wait"
    time.sleep(0.3)  # the slowed copy is now genuinely in flight
    return op, process, stdout, stderr


def test_an_inaccessible_log_tree_ends_with_the_stderr_document_only(harness, pinned_archive, tmp_path):
    """Case B of the delta review: <root>/logs itself is denied, so the outer
    layer cannot restore or write anything under logs/<op>. The caller
    observes the existing 0/2/3 contract: exit 2 and one error document on
    stderr that says the terminal record is unwritable. No file appears, no
    noise precedes the document, and the process stops promptly instead of
    running on."""
    reaper, root, env = harness
    _slow_cp_wrapper(env)
    op, process, stdout, stderr = _start_and_wait_for_staging(harness, env, pinned_archive, tmp_path)
    logs = root / "logs"
    op_dir = logs / op
    try:
        events_before = (op_dir / "events.ndjson").read_bytes()
        logs.chmod(0)
        denied_at = time.monotonic()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pytest.fail("the bootstrap kept running with an inaccessible log tree")
        stopped_in = time.monotonic() - denied_at
        with pytest.raises(PermissionError):
            (op_dir / "events.ndjson").stat()  # the caller cannot observe the files either
    finally:
        logs.chmod(0o700)
        if process.poll() is None:
            process.kill()
            process.wait()
    assert process.returncode == 2
    assert stopped_in < 2
    stdout.seek(0)
    stderr.seek(0)
    assert stdout.read() == ""
    lines = stderr.read().strip().splitlines()
    assert len(lines) == 1, lines  # only the error document, no shell noise
    document = json.loads(lines[0])
    assert document["kind"] == "stemwerk_module_install_error"
    error = document["error"]
    assert error["code"] == "cancelled"
    assert error["cancel"]["cancel_check_error"].startswith("EACCES: ")
    assert error["cancel"]["terminal_record"] == "unwritable"
    assert error["remains"]["staging_state"] == "removed"
    # Nothing durable could be written; the files are exactly what they were.
    assert not (op_dir / "result.json").exists()
    assert (op_dir / "events.ndjson").read_bytes() == events_before
    assert not (root / "tmp" / op).exists()


def test_a_read_only_operation_directory_is_restored_to_write_the_terminal_pair(harness, pinned_archive, tmp_path):
    """The marker is found (the directory is searchable) but the directory
    refuses writes: the owner restores write access on that one directory and
    still writes the terminal pair, with no failed-check detail because the
    marker lookup itself succeeded."""
    reaper, root, env = harness
    _slow_cp_wrapper(env)
    op, process, stdout, stderr = _start_and_wait_for_staging(harness, env, pinned_archive, tmp_path)
    op_dir = root / "logs" / op
    try:
        (op_dir / "cancel.request").touch()
        op_dir.chmod(0o500)
        process.wait(timeout=10)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        op_dir.chmod(0o700)
    assert process.returncode == 2
    result = json.loads((op_dir / "result.json").read_text())
    install_events.validate_result(result)
    error = result["document"]["error"]
    assert error["code"] == "cancelled"
    assert "cancel_check_error" not in error.get("cancel", {})
    assert error["cancel"]["operation_directory_mode_restored"] is True
    events = install_events.read_events(op_dir)
    assert events[-1]["state"] == "failed" and events[-1]["error_code"] == "cancelled"


def test_a_failed_staging_cleanup_is_reported_as_retained(harness, pinned_archive):
    """Sol's cleanup case (owner decision e): when the staging removal itself
    fails, the terminal result must say so — ``staging_state`` is ``retained``
    and names the actual path — instead of claiming a removal that did not
    happen. The cancelled outcome itself is preserved."""
    reaper, root, env = harness
    _slow_cp_wrapper(env)  # keep the archive staging wait alive for the marker window
    bin_dir = Path(env["PATH"].split(os.pathsep)[0])
    wrapper = bin_dir / "rm"
    wrapper.write_text(
        '#!/bin/sh\ncase "$*" in *"/bootstrap"*) exit 77;; esac\n'
        "exec " + shlex.quote(shutil.which("rm")) + ' "$@"\n',
        encoding="ascii",
    )
    wrapper.chmod(0o755)
    op = str(uuid.uuid4())
    stage = root / "tmp" / op / "bootstrap"
    process = subprocess.Popen(
        bootstrap_command(reaper, root, "--operation-id", op, "--archive", str(pinned_archive)),
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    try:
        deadline = time.monotonic() + 20
        while not (stage / "owner").is_file() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert (stage / "owner").is_file(), "bootstrap staging never appeared"
        (root / "logs" / op / "cancel.request").touch()
        _, stderr = process.communicate(timeout=20)
        assert process.returncode == 2, stderr
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    assert stage.is_dir() and (stage / "owner").is_file()  # really still there
    op_dir = root / "logs" / op
    events = install_events.read_events(op_dir)
    assert events[-1]["state"] == "failed"
    assert events[-1]["error_code"] == "cancelled"
    for event in events:
        install_events.validate_event(event)
    result = json.loads((op_dir / "result.json").read_text())
    install_events.validate_result(result)
    assert result["exit_code"] == 2
    error = result["document"]["error"]
    assert error["code"] == "cancelled"
    remains = error["remains"]
    assert remains["staging_state"] == "retained"
    assert f"tmp/{op}/bootstrap (removal failed)" in remains["retained"]


# --- the dedicated writer group and its pipe release gate (S8 fix3) --------------------
#
# Every process that can write the bootstrap staging runs in ONE process group started
# behind a FIFO gate: it writes nothing before the controller published bootstrap/group
# (staging path, real pgid, boot id) and sent "go <pgid>". Core only reads those records.

SCRIPT = REPO / "scripts/reaper/_internal/STEMwerk_Managed_Python_Linux.sh"


def _bin_dir(env):
    return Path(env["PATH"].split(os.pathsep)[0])


def _write_wrapper(env, name, body):
    wrapper = _bin_dir(env) / name
    wrapper.write_text(body, encoding="ascii")
    wrapper.chmod(0o755)
    return wrapper


def _wait_for(predicate, what, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.02)
    raise AssertionError(f"timed out waiting for {what}")


def _group_record(root, op):
    path = root / "tmp" / op / "bootstrap" / "group"
    return install_bootstrap.parse_group(path.read_bytes())


def _group_exists(pgid):
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    return True


def test_a_controller_killed_just_before_go_releases_nothing(harness, pinned_archive, tmp_path):
    """Deterministic: a ``sync`` wrapper blocks the controller's SECOND sync (the one right
    before ``go`` is written), after bootstrap/group is published. The controller is then
    killed with SIGKILL. EOF on the gate must end the waiting group, and no member may have
    written a payload or marker into the staging."""
    reaper, root, env = harness
    blocked, count, ran = tmp_path / "sync.blocked", tmp_path / "sync.count", tmp_path / "cp.ran"
    _write_wrapper(env, "sync", (
        "#!/bin/sh\n"
        f"n=$(cat {shlex.quote(str(count))} 2>/dev/null || echo 0); n=$((n + 1)); echo $n > {shlex.quote(str(count))}\n"
        f"if [ \"$n\" = 2 ]; then echo $$ > {shlex.quote(str(blocked))}; exec sleep 60; fi\n"
        f"exec {shlex.quote(shutil.which('sync'))} \"$@\"\n"))
    _write_wrapper(env, "cp", f"#!/bin/sh\ntouch {shlex.quote(str(ran))}\nexec {shlex.quote(shutil.which('cp'))} \"$@\"\n")
    op = str(uuid.uuid4())
    process = subprocess.Popen(
        bootstrap_command(reaper, root, "--operation-id", op, "--archive", str(pinned_archive)),
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
    )
    blocked_pid = None
    try:
        blocked_pid = int(_wait_for(lambda: blocked.exists() and blocked.read_text().strip(), "the blocked sync").strip())
        record = _group_record(root, op)
        pgid = record["pgid"]
        assert _group_exists(pgid), "the waiting worker group should be alive before go"
        assert record["staging"] == str(root / "tmp" / op / "bootstrap")
        assert record["boot_id"] == (Path("/proc/sys/kernel/random/boot_id").read_text().strip())
        # fix4: the namespace recorded with the PGID is the controller's own (the viewpoint
        # from which the PGID number was read)
        assert record["pid_namespace"] == os.readlink("/proc/self/ns/pid")
        os.kill(process.pid, signal.SIGKILL)
        process.wait(timeout=10)
        # EOF reaches the group although the controller's blocked sync child is still alive
        # (it was started with the gate closed): the group exits on its own.
        _wait_for(lambda: not _group_exists(pgid), "the waiting group to end on EOF", timeout=5)
        stage = root / "tmp" / op / "bootstrap"
        assert sorted(entry.name for entry in stage.iterdir()) <= ["gate", "group", "group.tmp", "owner"]
        assert not ran.exists(), "the copy step must never have started"
        assert not (stage / "python.tar.gz").exists()
    finally:
        if blocked_pid:
            try:
                os.kill(blocked_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if process.poll() is None:
            process.kill()
            process.wait()


@pytest.mark.parametrize("message", [b"", b"go", b"go 123", b"nope\n", b"go abc\n", b"go 1\n", b"GO 4242\n"])
def test_the_worker_ends_without_a_write_on_eof_incomplete_or_wrong_input(tmp_path, message):
    stage = tmp_path / "stage"
    stage.mkdir()
    env = {**os.environ, "W_STAGE": str(stage), "W_ARCHIVE": str(stage / "python.tar.gz"), "W_CUSTOM": "/nonexistent",
           "W_SRC": str(tmp_path), "W_ROOT": str(tmp_path), "W_NAME": "x", "W_CONTROLLER": str(os.getpid())}
    # its own session and group, as under the controller's setsid (a runner that is itself
    # in process group 1 would otherwise make "go 1" a valid release)
    worker = subprocess.Popen(["/bin/sh", str(SCRIPT), "--stemwerk-bootstrap-worker"], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, start_new_session=True)
    worker.communicate(input=message, timeout=10)
    assert worker.returncode == 3
    assert list(stage.iterdir()) == []


def test_the_worker_refuses_a_go_for_a_group_it_is_not_in(tmp_path):
    """A well-formed ``go`` whose group id is not the worker's own is not a release."""
    stage = tmp_path / "stage"
    stage.mkdir()
    env = {**os.environ, "W_STAGE": str(stage), "W_ARCHIVE": str(stage / "python.tar.gz"), "W_CUSTOM": "/nonexistent",
           "W_SRC": str(tmp_path), "W_ROOT": str(tmp_path), "W_NAME": "x", "W_CONTROLLER": str(os.getpid())}
    worker = subprocess.Popen(["/bin/sh", str(SCRIPT), "--stemwerk-bootstrap-worker"], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, start_new_session=True)
    worker.communicate(input=f"go {os.getpgrp() + 7}\n".encode(), timeout=10)  # not its group (its own pid is)
    assert worker.returncode == 3
    assert list(stage.iterdir()) == []


def test_a_controller_killed_after_go_leaves_a_group_that_stale_cleanup_respects(harness, pinned_archive, tmp_path):
    """The controller dies (SIGKILL) while the copy is in flight. The 15 minutes of silence
    are SIMULATED with a clock offset on a REAL install-lock acquisition; the writer group
    and the dead owner are real. While the group lives the staging stays and the writer can
    still create a NEW file through the original pathname (read by a separate process); once
    the group is gone the same staging is cleaned."""
    reaper, root, env = harness
    started = tmp_path / "cp.started"
    _write_wrapper(env, "cp", (
        "#!/bin/sh\n"
        f"touch {shlex.quote(str(started))}\n"
        "sleep 6\n"
        f"exec {shlex.quote(shutil.which('cp'))} \"$@\"\n"))
    op = str(uuid.uuid4())
    process = subprocess.Popen(
        bootstrap_command(reaper, root, "--operation-id", op, "--archive", str(pinned_archive)),
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
    )
    stage = root / "tmp" / op / "bootstrap"
    try:
        _wait_for(started.exists, "the copy to start")
        pgid = _group_record(root, op)["pgid"]
        os.kill(process.pid, signal.SIGKILL)  # abrupt death: no trap runs
        process.wait(timeout=10)
        assert _group_exists(pgid), "the writer group must outlive its controller"
        assert not (stage / "python.tar.gz").exists()
        lock = install_lock.acquire(root, str(uuid.uuid4()), clock=lambda: time.time() + 1000)
        try:
            statuses = {e.operation_id: e.status for e in lock.bootstrap_cleanup.entries}
        finally:
            lock.release()
        assert statuses == {op: install_bootstrap.KEPT_WRITER_GROUP_ALIVE}
        assert stage.is_dir()
        # The writer creates a NEW file through the original pathname after that cleanup ran.
        _wait_for((stage / "python.tar.gz").exists, "the surviving copy to create its file")
        read_back = subprocess.run(["sha256sum", str(stage / "python.tar.gz")], capture_output=True, text=True)
        assert read_back.stdout.split()[0] == PIN.sha256
        # The group ends by itself (the worker notices the dead controller after its step).
        _wait_for(lambda: not _group_exists(pgid), "the writer group to end", timeout=15)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    lock = install_lock.acquire(root, str(uuid.uuid4()), clock=lambda: time.time() + 1000)
    try:
        assert [(e.operation_id, e.outcome) for e in lock.bootstrap_cleanup.entries] == [(op, install_bootstrap.REMOVED)]
    finally:
        lock.release()
    assert not stage.exists()


def test_cancellation_stops_a_term_ignoring_group_and_spares_an_unrelated_sentinel(harness, pinned_archive, tmp_path):
    """TERM-ignoring writers plus an unrelated sentinel in another session. Local limits,
    measured from the marker: the controller starts stopping the group within 2 s and the
    whole shutdown (TERM grace, then KILL) ends within 12 s. The terminal pair is written by
    the controller (decision C: failed event, exit 2, result error.code cancelled)."""
    reaper, root, env = harness
    started = tmp_path / "cp.started"
    _write_wrapper(env, "cp", (
        "#!/bin/sh\n"
        "trap '' TERM\n"
        f"touch {shlex.quote(str(started))}\n"
        "sleep 60 &\nsleep 60 &\nwait\n"))
    sentinel = subprocess.Popen(["sleep", "60"], start_new_session=True)
    op = str(uuid.uuid4())
    process = subprocess.Popen(
        bootstrap_command(reaper, root, "--operation-id", op, "--archive", str(pinned_archive)),
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
    )
    try:
        _wait_for(started.exists, "the TERM-ignoring writer to start")
        pgid = _group_record(root, op)["pgid"]
        marker = root / "logs" / op / "cancel.request"
        marker.touch()
        t0 = time.monotonic()
        leader_gone = None
        while process.poll() is None and time.monotonic() - t0 < 30:
            if leader_gone is None:
                try:
                    os.kill(pgid, 0)
                except ProcessLookupError:
                    leader_gone = time.monotonic() - t0
                else:
                    state = Path(f"/proc/{pgid}/stat").read_text().rsplit(")", 1)[1].split()[0]
                    if state == "Z":
                        leader_gone = time.monotonic() - t0
            time.sleep(0.01)
        shutdown = time.monotonic() - t0
        process.wait(timeout=5)
        assert process.returncode == 2
        assert leader_gone is not None and leader_gone <= 2.0, leader_gone  # detection: TERM reached the group
        assert 4.5 <= shutdown <= 12.0, shutdown  # the KILL came only after the 5 s TERM grace
        assert not _group_exists(pgid)
        assert sentinel.poll() is None, "the unrelated sentinel must survive"
    finally:
        sentinel.kill()
        sentinel.wait()
        if process.poll() is None:
            process.kill()
            process.wait()
    op_dir = root / "logs" / op
    events = install_events.read_events(op_dir)
    assert events[-1]["state"] == "failed" and events[-1]["error_code"] == "cancelled"
    result = json.loads((op_dir / "result.json").read_text())
    install_events.validate_result(result)
    assert result["exit_code"] == 2 and result["document"]["error"]["code"] == "cancelled"
    assert result["document"]["error"]["remains"] == {"staging_state": "removed", "retained": []}
    assert not (root / "tmp" / op).exists()


def test_a_group_that_cannot_be_shown_empty_keeps_the_staging_and_says_so(harness, pinned_archive, tmp_path):
    """Emptiness is not provable: the controller runs under a child subreaper that never
    reaps, so the KILLed group members stay as zombies in the group (``killpg(pgid, 0)``
    keeps answering). The bounded wait ends, the staging is retained, and the result
    states the uncertainty (decision C otherwise unchanged: failed event, exit 2)."""
    reaper, root, env = harness
    started = tmp_path / "cp.started"
    _write_wrapper(env, "cp", (
        "#!/bin/sh\n"
        f"touch {shlex.quote(str(started))}\n"
        "sleep 60 &\nsleep 60 &\nwait\n"))
    op = str(uuid.uuid4())
    launcher = (
        "import ctypes, subprocess, sys\n"
        "ctypes.CDLL(None).prctl(36, 1, 0, 0, 0)  # PR_SET_CHILD_SUBREAPER: orphans come here and are never reaped\n"
        "p = subprocess.Popen(sys.argv[1:], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n"
        "sys.exit(p.wait())\n"
    )
    process = subprocess.Popen(
        [sys.executable, "-c", launcher, *bootstrap_command(reaper, root, "--operation-id", op, "--archive", str(pinned_archive))],
        env=env, start_new_session=True,
    )
    try:
        _wait_for(started.exists, "the writer to start")
        (root / "logs" / op / "cancel.request").touch()
        t0 = time.monotonic()
        process.wait(timeout=30)
        shutdown = time.monotonic() - t0
        assert process.returncode == 2
        # emptiness could not be shown, so the controller used its whole bounded wait
        # (5 s after TERM, 5 s after KILL) and no more
        assert 9.5 <= shutdown <= 14.0, shutdown
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    op_dir = root / "logs" / op
    events = install_events.read_events(op_dir)
    assert events[-1]["state"] == "failed" and events[-1]["error_code"] == "cancelled"
    result = json.loads((op_dir / "result.json").read_text())
    install_events.validate_result(result)
    remains = result["document"]["error"]["remains"]
    assert remains["staging_state"] == "retained"
    assert remains["retained"] == [f"tmp/{op}/bootstrap (writer group not proven gone)"]
    assert "may still be alive" in remains["uncertainty"]
    assert (root / "tmp" / op / "bootstrap" / "group").is_file()  # the evidence stays with the staging


def test_a_record_that_cannot_be_made_durable_releases_nothing(harness, pinned_archive, tmp_path):
    """``sync`` fails, so bootstrap/group is not durable: the pipe is closed without
    ``go``, the waiting group ends, no writer runs, and the failure is reported."""
    reaper, root, env = harness
    ran = tmp_path / "cp.ran"
    _write_wrapper(env, "sync", "#!/bin/sh\nexit 1\n")
    _write_wrapper(env, "cp", f"#!/bin/sh\ntouch {shlex.quote(str(ran))}\nexec {shlex.quote(shutil.which('cp'))} \"$@\"\n")
    op = str(uuid.uuid4())
    process = subprocess.run(
        bootstrap_command(reaper, root, "--operation-id", op, "--archive", str(pinned_archive)),
        env=env, capture_output=True, text=True, timeout=60,
    )
    assert process.returncode == 2
    events = install_events.read_events(root / "logs" / op)
    assert events[-1]["state"] == "failed" and events[-1]["error_code"] == "staging_unavailable"
    assert not ran.exists(), "no writer may run before go"
    assert not (root / "tmp" / op / "bootstrap").exists()
    assert not (root / "runtimes/python" / PIN.name).exists()


def _spawn_worker(tmp_path, *, controller_pid=None):
    stage = tmp_path / "stage"
    stage.mkdir(exist_ok=True)
    env = {**os.environ, "W_STAGE": str(stage), "W_ARCHIVE": str(stage / "python.tar.gz"), "W_CUSTOM": "/nonexistent",
           "W_SRC": str(tmp_path), "W_ROOT": str(tmp_path), "W_NAME": "x", "W_CONTROLLER": str(controller_pid or os.getpid())}
    return subprocess.Popen(["/bin/sh", str(SCRIPT), "--stemwerk-bootstrap-worker"], stdin=subprocess.PIPE, env=env,
                            start_new_session=True), stage  # the worker is its own group leader, as under setsid


def test_the_worker_is_released_only_by_a_complete_go_for_its_own_group(tmp_path):
    # incomplete line (no LF), right group id: EOF must not count as a release
    worker, stage = _spawn_worker(tmp_path)
    worker.stdin.write(f"go {worker.pid}".encode())
    worker.stdin.close()
    assert worker.wait(timeout=5) == 3
    assert list(stage.iterdir()) == []
    # complete line for its own group: released (it now waits for step requests)
    worker, stage = _spawn_worker(tmp_path)
    try:
        worker.stdin.write(f"go {worker.pid}\n".encode())
        worker.stdin.flush()
        time.sleep(0.5)
        assert worker.poll() is None, "a complete go for its own group releases the worker"
        assert list(stage.iterdir()) == []  # released, but nothing is written until a step is requested
    finally:
        os.killpg(worker.pid, signal.SIGKILL)
        worker.wait(timeout=5)


def test_a_successful_run_leaves_no_writer_group(harness, pinned_archive, tmp_path):
    reaper, root, env = harness
    recorded = tmp_path / "cp.pgrp"
    _write_wrapper(env, "cp", (
        "#!/bin/sh\n"
        "( read -r line < /proc/$$/stat; rest=${line##*) }; set -- $rest; "
        f"echo $3 > {shlex.quote(str(recorded))} )\n"
        f"exec {shlex.quote(shutil.which('cp'))} \"$@\"\n"))
    result = run(harness, "plan", "--module", "drum_kit", archive=pinned_archive, env={})
    assert result.returncode == 0, result.stderr
    pgid = int(recorded.read_text())
    assert pgid > 1 and pgid != os.getpgrp()
    assert not _group_exists(pgid), "the worker group must be stopped before the run continues"
    assert not any((root / "tmp").glob("*/bootstrap"))



# --- S8 fix4: the PGID viewpoint of the controller ---------------------------------------


def _block_before_go(env, tmp_path):
    blocked, count = tmp_path / "sync.blocked", tmp_path / "sync.count"
    _write_wrapper(env, "sync", (
        "#!/bin/sh\n"
        f"n=$(cat {shlex.quote(str(count))} 2>/dev/null || echo 0); n=$((n + 1)); echo $n > {shlex.quote(str(count))}\n"
        f"if [ \"$n\" = 2 ]; then echo $$ > {shlex.quote(str(blocked))}; exec sleep 60; fi\n"
        f"exec {shlex.quote(shutil.which('sync'))} \"$@\"\n"))
    return blocked


@pytest.mark.parametrize("readlink_output", ["pid:[0]", "pid:[]", "pid:[12", "net:[4026531840]", "garbage"])
def test_a_malformed_namespace_identity_is_recorded_empty(harness, pinned_archive, tmp_path, readlink_output):
    """The controller records the namespace only in its exact form; anything else is left
    empty, which Core treats as no proof (the staging is then kept, never removed early)."""
    reaper, root, env = harness
    blocked = _block_before_go(env, tmp_path)
    _write_wrapper(env, "readlink", f"#!/bin/sh\nprintf '%s\\n' {shlex.quote(readlink_output)}\n")
    op = str(uuid.uuid4())
    process = subprocess.Popen(
        bootstrap_command(reaper, root, "--operation-id", op, "--archive", str(pinned_archive)),
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
    )
    blocked_pid = None
    try:
        blocked_pid = int(_wait_for(lambda: blocked.exists() and blocked.read_text().strip(), "the blocked sync").strip())
        line = (root / "tmp" / op / "bootstrap" / "group").read_bytes()
        assert line.split(b"\t")[5] == b"\n"  # the sixth field is empty
        assert install_bootstrap.parse_group(line)["pid_namespace"] is None
    finally:
        if blocked_pid:
            try:
                os.kill(blocked_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=10)


def _docker_image(image):
    if shutil.which("docker") is None:
        return False
    try:
        return subprocess.run(["docker", "image", "inspect", image], capture_output=True, timeout=20).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


@pytest.mark.skipif(not _docker_image("ubuntu:24.04"), reason="needs docker with a local ubuntu:24.04 image (never pulled here)")
def test_a_proc_view_of_another_pid_namespace_releases_nothing_under_dash(pinned_archive, tmp_path):
    """REAL: the real entry under dash (ubuntu:24.04 /bin/sh), as this ordinary uid, in a
    nested PID namespace whose /proc still numbers the container's namespace (unshare
    --pid --fork without --mount-proc). The controller cannot show that /proc numbers its
    own namespace, so it starts no worker, publishes no group and reports a named failure."""
    base = tmp_path / "procview"
    base.mkdir(mode=0o700)
    binp = base / "bin"
    binp.mkdir()
    (binp / "cp").write_text(f'#!/bin/sh\ntouch {base}/cp.started\nexec /usr/bin/cp "$@"\n')
    (binp / "cp").chmod(0o755)
    root = base / "root"
    root.mkdir(mode=0o700)
    op = str(uuid.uuid4())
    inner = (f"exec unshare --pid --fork setpriv --reuid={os.getuid()} --regid={os.getgid()} --clear-groups "
             f"env PATH={binp}:/usr/bin:/bin HOME={base} LANG=C /bin/sh /repo/scripts/reaper/STEMwerk_Bootstrap_Linux.sh "
             f"--managed-python-bootstrap --root {root} --operation-id {op} --archive /pin/{pinned_archive.name} -- plan --module drum_kit")
    run = subprocess.run(
        ["docker", "run", "--rm", "--network", "none", "--cap-add", "SYS_ADMIN", "--security-opt", "seccomp=unconfined",
         "--security-opt", "apparmor=unconfined", "--mount", f"type=bind,src={tmp_path},dst={tmp_path}",
         "--mount", f"type=bind,src={REPO},dst=/repo,readonly",
         "--mount", f"type=bind,src={pinned_archive.parent},dst=/pin,readonly",
         "ubuntu:24.04", "/bin/sh", "-c", inner],
        capture_output=True, text=True, timeout=120,
    )
    assert run.returncode == 2, run.stderr
    document = json.loads(run.stderr.strip().splitlines()[-1])
    assert document["error"]["code"] == "bootstrap_prerequisite_unavailable"
    assert "does not number the PID namespace" in document["error"]["message"]
    assert not (base / "cp.started").exists()
    assert not (root / "tmp" / op / "bootstrap").exists()  # nothing released, nothing left
    events = install_events.read_events(root / "logs" / op)
    assert events[-1]["state"] == "failed" and events[-1]["error_code"] == "bootstrap_prerequisite_unavailable"
