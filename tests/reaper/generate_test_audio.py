#!/usr/bin/env python3
"""
Generate minimal test audio assets for REAPER testing.
Creates short synthetic audio files with simple waveforms for validation.
"""
import os
import sys
import argparse
from pathlib import Path

try:
    import numpy as np
    import soundfile as sf
except ImportError:
    print("Error: numpy and soundfile required. Install via: pip install numpy soundfile")
    sys.exit(1)


def generate_test_mix(output_path: Path, duration_sec: float = 10.0, sample_rate: int = 44100):
    """Generate a simple multi-component test mix."""
    print(f"Generating {duration_sec}s test mix at {sample_rate}Hz: {output_path}")
    
    t = np.linspace(0, duration_sec, int(sample_rate * duration_sec))
    
    # Simulate simple "stems"
    vocals = 0.3 * np.sin(2 * np.pi * 440 * t)  # 440Hz sine (vocals proxy)
    drums = 0.2 * np.random.randn(len(t)) * (np.sin(2 * np.pi * 2 * t) > 0)  # Noise pulses
    bass = 0.4 * np.sin(2 * np.pi * 110 * t)  # 110Hz sine (bass proxy)
    other = 0.2 * np.sin(2 * np.pi * 880 * t)  # 880Hz sine (other proxy)
    
    # Mix all components
    mix = vocals + drums + bass + other
    
    # Normalize to prevent clipping
    mix = mix / np.max(np.abs(mix)) * 0.9
    
    # Make stereo
    stereo_mix = np.column_stack([mix, mix])
    
    output_path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(output_path, stereo_mix, sample_rate)
    print(f"  Created: {output_path} ({duration_sec}s, stereo, {sample_rate}Hz)")


def generate_all_assets(assets_dir: Path):
    """Generate complete test asset suite."""
    print("\n=== Generating STEMwerk Test Assets ===\n")
    
    # Main test file
    generate_test_mix(assets_dir / "test_mix_10s.wav", duration_sec=10.0)
    
    # Short file for quick tests
    generate_test_mix(assets_dir / "test_mix_5s.wav", duration_sec=5.0)
    
    # Longer file for heavy tests (optional)
    # generate_test_mix(assets_dir / "test_mix_30s.wav", duration_sec=30.0)
    
    print(f"\n Test assets generated in: {assets_dir}")
    print("\nNext steps:")
    print("  1. Copy these to your REAPER project folder")
    print("  2. Run: python tests/reaper/run_reaper_test.py")


def main():
    parser = argparse.ArgumentParser(description="Generate test audio assets for STEMwerk")
    parser.add_argument("--output-dir", type=Path, 
                       default=Path(__file__).parent / "assets",
                       help="Output directory for test assets")
    parser.add_argument("--duration", type=float, default=10.0,
                       help="Duration in seconds for main test file")
    parser.add_argument("--sample-rate", type=int, default=44100,
                       help="Sample rate (Hz)")
    
    args = parser.parse_args()
    
    if args.output_dir.exists() and list(args.output_dir.glob("*.wav")):
        response = input(f"Assets already exist in {args.output_dir}. Overwrite? (y/N): ")
        if response.lower() != 'y':
            print("Cancelled.")
            return
    
    generate_all_assets(args.output_dir)


if __name__ == "__main__":
    main()
