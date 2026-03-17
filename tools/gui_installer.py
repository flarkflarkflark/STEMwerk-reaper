#!/usr/bin/env python3
"""
Simple cross-platform GUI installer prototype using PySimpleGUI.
Supports a headless mode `--no-gui` that runs the GPU check and prints summary.

Run:
  python tools/gui_installer.py        # GUI mode (requires PySimpleGUI)
  python tools/gui_installer.py --no-gui
"""
import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(__file__)
CHECK_FILE = os.path.join(HERE, '..', 'gpu_check.json')


def run_gpu_check():
    cmd = [sys.executable, os.path.join(HERE, 'gpu_check.py')]
    try:
        subprocess.check_call(cmd)
    except subprocess.CalledProcessError:
        pass
    # load results if present
    p = os.path.join(os.getcwd(), 'gpu_check.json')
    if os.path.exists(p):
        with open(p, 'r', encoding='utf-8') as f:
            return json.load(f)
    return None


def print_summary(info):
    if not info:
        print('No gpu_check.json available.')
        return
    print('\nGPU Check Summary:')
    print(json.dumps({
        'platform': info.get('platform'),
        'torch': info.get('torch'),
        'cuda_available': info.get('cuda_available'),
        'nvidia_smi': bool(info.get('nvidia_smi')),
        'rocm': info.get('rocm_detected'),
        'mps': info.get('mps_available'),
        'directml': info.get('directml_possible')
    }, indent=2))


def gui_main():
    try:
        import PySimpleGUI as sg
    except Exception:
        print('PySimpleGUI not installed. Falling back to headless mode (running GPU check).')
        info = run_gpu_check()
        print_summary(info)
        return

    sg.theme('DefaultNoMoreNagging')
    layout = [
        [sg.Text('STEMwerk GPU Installer', font=('Helvetica', 16))],
        [sg.HorizontalSeparator()],
        [sg.Multiline('', size=(80, 20), key='-OUT-')],
        [sg.Button('Run GPU Check', key='-RUN-'), sg.Button('Open installers folder', key='-OPEN-'), sg.Button('Close')]
    ]

    window = sg.Window('STEMwerk Installer', layout, finalize=True)

    while True:
        event, values = window.read()
        if event in (sg.WIN_CLOSED, 'Close'):
            break
        if event == '-RUN-':
            window['-OUT-'].update('Running GPU check...\n')
            window.refresh()
            info = run_gpu_check()
            if not info:
                window['-OUT-'].update('GPU check failed or produced no output.\n', append=True)
            else:
                window['-OUT-'].update(json.dumps(info, indent=2), append=True)
        if event == '-OPEN-':
            installers_dir = os.path.join(os.getcwd(), 'installers')
            if os.path.isdir(installers_dir):
                if sys.platform.startswith('win'):
                    os.startfile(installers_dir)
                elif sys.platform.startswith('darwin'):
                    subprocess.call(['open', installers_dir])
                else:
                    subprocess.call(['xdg-open', installers_dir])
    window.close()


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--no-gui', action='store_true', help='Run headless check and print results')
    args = p.parse_args()
    if args.no_gui:
        info = run_gpu_check()
        print_summary(info)
        return
    gui_main()


if __name__ == '__main__':
    main()
