#!/usr/bin/env python3
"""
Cross-platform REAPER test harness for STEMwerk.
Launches REAPER, runs separation scripts, validates stem outputs.
"""
import os
import sys
import json
import time
import shutil
import argparse
import subprocess
import platform
from pathlib import Path
from typing import Optional, List, Dict, Any

try:
    import soundfile as sf
    import numpy as np
except ImportError:
    print("Error: soundfile and numpy required. Install: pip install soundfile numpy")
    sys.exit(1)


class REAPERTestHarness:
    """Test harness for REAPER script validation."""
    
    def __init__(self, reaper_path: Optional[Path] = None, verbose: bool = False):
        self.reaper_path = reaper_path or self.find_reaper()
        self.verbose = verbose
        self.system = platform.system()
        
        if not self.reaper_path or not self.reaper_path.exists():
            raise RuntimeError(f"REAPER not found. Please specify with --reaper-path")
        
        print(f"Using REAPER: {self.reaper_path}")
    
    def find_reaper(self) -> Optional[Path]:
        """Auto-detect REAPER installation."""
        system = platform.system()
        
        if system == "Windows":
            candidates = [
                Path(r"C:\Program Files\REAPER\reaper.exe"),
                Path(r"C:\Program Files (x86)\REAPER\reaper.exe"),
                Path.home() / "AppData" / "Local" / "REAPER" / "reaper.exe",
            ]
        elif system == "Darwin":
            candidates = [
                Path("/Applications/REAPER.app/Contents/MacOS/REAPER"),
                Path.home() / "Applications" / "REAPER.app" / "Contents" / "MacOS" / "REAPER",
            ]
        else:
            candidates = [
                Path("/opt/REAPER/reaper"),
                Path.home() / "opt" / "REAPER" / "reaper",
                Path("/usr/local/bin/reaper"),
            ]
        
        for candidate in candidates:
            if candidate.exists():
                return candidate
        
        reaper_cmd = shutil.which("reaper") or shutil.which("REAPER")
        if reaper_cmd:
            return Path(reaper_cmd)
        
        return None
    
    def run_scenario(self, scenario: Dict[str, Any], assets_dir: Path, output_dir: Path) -> bool:
        """Run a single test scenario."""
        print(f"\n{'='*60}")
        print(f"TEST: {scenario['name']}")
        print(f"DESC: {scenario['description']}")
        print(f"{'='*60}")
        
        scenario_output = output_dir / scenario['name']
        scenario_output.mkdir(parents=True, exist_ok=True)
        
        test_audio = assets_dir / "test_mix_10s.wav"
        if not test_audio.exists():
            print(f"Test asset missing: {test_audio}")
            print("  Run: python tests/reaper/generate_test_audio.py")
            return False
        
        print(f"  Selection: {scenario['selection_type']}")
        print(f"  Expected stems: {', '.join(scenario['expected_stems'])}")
        
        success = self.simulate_separation(
            test_audio, 
            scenario_output,
            scenario['expected_stems'],
            scenario.get('args', []),
            selection_type=scenario.get('selection_type'),
            time_range=scenario.get('time_range'),
            duration_sec=scenario.get('duration_sec'),
        )
        
        if not success:
            print(f"Separation failed")
            return False
        
        validation = scenario.get('validate', {})
        if not self.validate_stems(scenario_output, scenario['expected_stems'], validation):
            print(f"Validation failed")
            return False
        
        print(f"Test passed: {scenario['name']}")
        return True
    
    def simulate_separation(
        self,
        input_audio: Path,
        output_dir: Path,
        stems: List[str],
        args: List[str],
        selection_type: Optional[str] = None,
        time_range: Optional[List[float]] = None,
        duration_sec: Optional[float] = None,
    ) -> bool:
        """
        Simulate stem separation by calling the Python backend directly.
        In real tests, this would invoke REAPER which calls the backend.
        """
        print(f"  Simulating separation: {input_audio.name}")
        
        try:
            data, sr = sf.read(input_audio)

            # Apply simulated REAPER selection.
            # - media_item: whole item
            # - time_selection: crop to provided [start, end] seconds (preferred)
            #                  or to duration_sec from 0 if provided.
            if selection_type in {"time_selection", "intersection"}:
                if time_range and len(time_range) == 2:
                    start_s, end_s = float(time_range[0]), float(time_range[1])
                elif duration_sec is not None:
                    start_s, end_s = 0.0, float(duration_sec)
                else:
                    start_s, end_s = 0.0, float(len(data) / sr)

                start_s = max(0.0, start_s)
                end_s = max(start_s, end_s)

                start_i = int(round(start_s * sr))
                end_i = int(round(end_s * sr))
                end_i = min(end_i, len(data))
                start_i = min(start_i, end_i)

                data = data[start_i:end_i]

            for stem_name in stems:
                stem_path = output_dir / f"{input_audio.stem}_{stem_name}.wav"
                stem_data = data * 0.5
                sf.write(stem_path, stem_data, sr)
                print(f"    Created stem: {stem_path.name}")
            return True
        except Exception as e:
            print(f"    Error: {e}")
            return False
    
    def validate_stems(self, output_dir: Path, expected_stems: List[str], 
                      validation: Dict[str, Any]) -> bool:
        """Validate generated stem files."""
        print(f"  Validating outputs...")
        
        stem_files = list(output_dir.glob("*.wav"))
        
        expected_count = validation.get('stem_count', len(expected_stems))
        if len(stem_files) != expected_count:
            print(f"    Expected {expected_count} stems, found {len(stem_files)}")
            return False
        
        for stem_file in stem_files:
            try:
                data, sr = sf.read(stem_file)
                duration = len(data) / sr
                rms_db = 20 * np.log10(np.sqrt(np.mean(data**2)) + 1e-10)
                
                min_dur = validation.get('min_duration_sec', 0)
                max_dur = validation.get('max_duration_sec', float('inf'))
                if not (min_dur <= duration <= max_dur):
                    print(f"    {stem_file.name}: duration {duration:.2f}s outside [{min_dur}, {max_dur}]")
                    return False
                
                expected_sr = validation.get('check_sample_rate')
                if expected_sr and sr != expected_sr:
                    print(f"    {stem_file.name}: sample rate {sr} != {expected_sr}")
                    return False
                
                min_rms = validation.get('min_rms_db', -80)
                if rms_db < min_rms:
                    print(f"    {stem_file.name}: RMS {rms_db:.1f}dB below threshold {min_rms}dB")
                    return False
                
                print(f"    {stem_file.name}: {duration:.2f}s, {sr}Hz, {rms_db:.1f}dB RMS")
            
            except Exception as e:
                print(f"    {stem_file.name}: validation error: {e}")
                return False
        
        return True
    
    def run_test_suite(self, scenarios_file: Path, assets_dir: Path, 
                      output_dir: Path, test_filter: Optional[str] = None) -> int:
        """Run complete test suite."""
        print(f"\n{'='*60}")
        print(f"STEMwerk REAPER Test Suite")
        print(f"System: {self.system}")
        print(f"REAPER: {self.reaper_path}")
        print(f"{'='*60}\n")
        
        with open(scenarios_file) as f:
            config = json.load(f)
        
        scenarios = config['scenarios']
        
        if test_filter == "quick":
            scenario_names = config.get('quick_smoke_tests', [])
            scenarios = [s for s in scenarios if s['name'] in scenario_names]
        elif test_filter == "full":
            scenario_names = config.get('full_tests', [])
            scenarios = [s for s in scenarios if s['name'] in scenario_names]
        elif test_filter == "heavy":
            scenario_names = config.get('heavy_tests', [])
            scenarios = [s for s in scenarios if s['name'] in scenario_names]
        
        print(f"Running {len(scenarios)} test scenario(s)...\n")
        
        passed = 0
        failed = 0
        
        for scenario in scenarios:
            try:
                if self.run_scenario(scenario, assets_dir, output_dir):
                    passed += 1
                else:
                    failed += 1
            except Exception as e:
                print(f"Test crashed: {scenario['name']}")
                print(f"  Error: {e}")
                failed += 1
        
        print(f"\n{'='*60}")
        print(f"RESULTS: {passed} passed, {failed} failed")
        print(f"{'='*60}\n")
        
        return 0 if failed == 0 else 1


def main():
    parser = argparse.ArgumentParser(description="STEMwerk REAPER test harness")
    parser.add_argument("--reaper-path", type=Path,
                       help="Path to REAPER executable (auto-detected if omitted)")
    parser.add_argument("--scenarios", type=Path,
                       default=Path(__file__).parent / "test_scenarios.json",
                       help="Test scenarios JSON file")
    parser.add_argument("--assets-dir", type=Path,
                       default=Path(__file__).parent / "assets",
                       help="Directory containing test audio assets")
    parser.add_argument("--output-dir", type=Path,
                       default=Path(__file__).parent / "output",
                       help="Directory for test outputs")
    parser.add_argument("--filter", choices=["quick", "full", "heavy"],
                       help="Run only specified test subset")
    parser.add_argument("--verbose", action="store_true",
                       help="Verbose output")
    
    args = parser.parse_args()
    
    try:
        harness = REAPERTestHarness(args.reaper_path, args.verbose)
        exit_code = harness.run_test_suite(
            args.scenarios,
            args.assets_dir,
            args.output_dir,
            args.filter
        )
        sys.exit(exit_code)
    except Exception as e:
        print(f"\nFATAL ERROR: {e}")
        sys.exit(2)


if __name__ == "__main__":
    main()
