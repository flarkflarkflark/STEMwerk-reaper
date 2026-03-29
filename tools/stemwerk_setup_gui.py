
#!/usr/bin/env python3
"""
STEMwerk Setup Wizard (Cross-platform, Windows-style)
Automatic, stepwise installer for Linux/macOS/Windows.
"""
import os
import sys
import subprocess
import PySimpleGUI as sg
import shutil
import platform


def read_repo_version():
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
    version_path = os.path.join(root, "VERSION")
    try:
        with open(version_path, "r", encoding="utf-8") as handle:
            version = handle.read().strip()
            return version or "unknown"
    except OSError:
        return "unknown"

APP_TITLE = f"Setup - STEMwerk version {read_repo_version()}"
STEPS = ["Runtime", "Python + venv", "FFmpeg", "Core packages"]

def run_cmd(cmd, cwd=None):
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=cwd)
        return result.returncode, result.stdout + result.stderr
    except Exception as e:
        return 1, str(e)

def python_exe(venv_path):
    if platform.system() == "Windows":
        return os.path.join(venv_path, "Scripts", "python.exe")
    else:
        return os.path.join(venv_path, "bin", "python")

def venv_exists(venv_path):
    return os.path.exists(python_exe(venv_path))

def ffmpeg_exists():
    return shutil.which("ffmpeg") is not None

def reaper_scripts_dir():
    if platform.system() == "Windows":
        return os.path.expandvars(r"%USERPROFILE%\\Documents\\REAPER\\Scripts")
    elif platform.system() == "Darwin":
        return os.path.expanduser("~/Library/Application Support/REAPER/Scripts")
    else:
        return os.path.expanduser("~/.config/REAPER/Scripts")

def step_bar(current):
    bar = []
    for i, step in enumerate(STEPS):
        color = '#0078D7' if i == current else ('#d9534f' if i < current else '#cccccc')
        bar.append(sg.Text(f"{i+1}. {step}", background_color=color, text_color='white', pad=(5,5), font=('Segoe UI', 11, 'bold')))
    return bar

sg.theme('DefaultNoMoreNagging')
layout = [
    [sg.Text('Installing', font=('Segoe UI', 14, 'bold'))],
    [sg.Text('Please wait while Setup installs STEMwerk on your computer.')],
    [sg.Text('First-time setup can take several minutes. STEMwerk is preparing the runtime, creating the Python environment, checking FFmpeg, and installing core packages.')],
    [sg.Column([step_bar(0)], key='-STEPS-', background_color='#f0f0f0')],
    [sg.ProgressBar(100, orientation='h', size=(50, 20), key='-PROG-')],
    [sg.Multiline('', size=(80, 16), key='-OUT-', autoscroll=True, font=('Consolas', 10))],
    [sg.Button('Cancel', key='-CANCEL-'), sg.Button('Finish', key='-FINISH-', visible=False)]
]

window = sg.Window(APP_TITLE, layout, finalize=True)

def update_step(step_idx):
    window['-STEPS-'].update(step_bar(step_idx))

def log(msg):
    window['-OUT-'].update(msg + '\n', append=True)

def set_progress(pct):
    window['-PROG-'].update_bar(pct)

def auto_setup():

    total_steps = 5
    venv_path = os.path.join(os.getcwd(), ".venv")
    # 1. Runtime
    update_step(0)
    set_progress(5)
    log("[1/5] Checking Python runtime...")
    py = shutil.which("python3.12") or shutil.which("python3.11") or shutil.which("python3") or shutil.which("python")
    if not py:
        log("ERROR: Python 3.11/3.12 not found on PATH.")
        return False
    log(f"Found Python: {py}")
    set_progress(10)

    # 2. Python + venv
    update_step(1)
    log("[2/5] Creating or reusing venv...")
    if not venv_exists(venv_path):
        rc, out = run_cmd(f'{py} -m venv "{venv_path}"')
        log(out)
        if rc != 0:
            log("ERROR: Failed to create venv.")
            return False
    else:
        log("Venv already exists.")
    pyvenv = python_exe(venv_path)
    log(f"Using venv Python: {pyvenv}")
    set_progress(25)

    # 3. FFmpeg
    update_step(2)
    log("[3/5] Checking FFmpeg...")
    if not ffmpeg_exists():
        log("WARNING: FFmpeg not found on PATH. Please install ffmpeg for full functionality.")
    else:
        log("FFmpeg found.")
    set_progress(40)

    # 4. Core packages (detect GPU/ROCm/MPS)
    update_step(3)
    log("[4/5] Installing core Python packages...")
    # Detect ROCm/NVIDIA/MPS
    gpu_hint = ''
    try:
        import platform as _pf
        sysname = _pf.system().lower()
        if sysname == 'darwin':
            gpu_hint = 'mps'
        elif sysname == 'linux':
            # Check for ROCm
            if os.path.exists('/opt/rocm') or shutil.which('rocminfo'):
                gpu_hint = 'rocm'
            elif shutil.which('nvidia-smi'):
                gpu_hint = 'cuda'
    except Exception:
        pass
    reqs = ['pip', 'wheel', 'PySimpleGUI', 'stemwerk-core', 'numpy<2.4']
    if gpu_hint == 'rocm':
        reqs.append('torch --extra-index-url https://download.pytorch.org/whl/rocm5.7')
        log("ROCm detected: installing ROCm-enabled torch.")
    elif gpu_hint == 'cuda':
        reqs.append('torch')  # Let pip pick CUDA if available
        log("NVIDIA detected: installing CUDA/CPU torch.")
    elif gpu_hint == 'mps':
        reqs.append('torch')  # macOS MPS
        log("macOS detected: installing MPS/CPU torch.")
    else:
        reqs.append('torch')  # fallback
        log("No GPU detected: installing CPU torch.")
    for i, pkg in enumerate(reqs):
        set_progress(40 + int((i/len(reqs))*40))
        if '--extra-index-url' in pkg:
            base, *args = pkg.split()
            rc, out = run_cmd(f'"{pyvenv}" -m pip install --upgrade {base} {" ".join(args)}')
        else:
            rc, out = run_cmd(f'"{pyvenv}" -m pip install --upgrade {pkg}')
        log(out)
        if rc != 0:
            log(f"ERROR: Failed to install {pkg}.")
            return False
    set_progress(80)

    # 5. REAPER-integratie
    update_step(4)
    log("[5/5] Copying STEMwerk scripts to REAPER...")
    src = os.path.join(os.getcwd(), 'scripts', 'reaper')
    dst = reaper_scripts_dir()
    if not os.path.exists(src):
        log(f'Source scripts not found: {src}')
        return False
    os.makedirs(dst, exist_ok=True)
    try:
        for fname in os.listdir(src):
            shutil.copy2(os.path.join(src, fname), dst)
        log(f'Copied STEMwerk scripts to {dst}')
    except Exception as e:
        log(f'Failed to copy scripts: {e}')
        return False
    set_progress(100)
    log("\nSetup complete! STEMwerk is ready to use in REAPER.")
    return True

# --- Main event loop ---

setup_done = False
setup_success = False
log_content = ""
while True:
    event, values = window.read(timeout=100)
    if event in (sg.WIN_CLOSED, '-CANCEL-'):
        break
    if not setup_done:
        window['-CANCEL-'].update(disabled=True)
        ok = auto_setup()
        setup_done = True
        setup_success = ok
        window['-CANCEL-'].update(disabled=False)
        window['-FINISH-'].update(visible=True)
        log_content = window['-OUT-'].get()
    if event == '-FINISH-':
        break

window.close()

# --- After-install summary window ---
if setup_done:
    summary = "STEMwerk setup completed successfully!" if setup_success else "STEMwerk setup failed. See log for details."
    layout2 = [
        [sg.Text('STEMwerk Setup Summary', font=('Segoe UI', 14, 'bold'))],
        [sg.Text(summary)],
        [sg.Multiline(log_content, size=(80, 16), disabled=True, font=('Consolas', 10))],
        [sg.Checkbox('Open setup log after closing', key='-OPENLOG-', default=False)],
        [sg.Checkbox('Open usage guide after closing', key='-OPENREADME-', default=False)],
        [sg.Button('Close', key='-CLOSE-')]
    ]
    win2 = sg.Window('STEMwerk Setup - Summary', layout2, finalize=True)
    while True:
        ev2, vals2 = win2.read()
        if ev2 in (sg.WIN_CLOSED, '-CLOSE-'):
            break
    win2.close()
    # Open log or readme if requested
    import tempfile, webbrowser
    if vals2.get('-OPENLOG-'):
        with tempfile.NamedTemporaryFile('w', delete=False, suffix='.txt', encoding='utf-8') as f:
            f.write(log_content)
            webbrowser.open(f.name)
    if vals2.get('-OPENREADME-'):
        readme_path = os.path.abspath(os.path.join(os.path.dirname(__file__), 'STEMwerk_Setup_Guide_Linux_macOS.md'))
        if os.path.exists(readme_path):
            webbrowser.open(readme_path)
