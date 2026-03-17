#!/usr/bin/env python3
"""
Generate minimal REAPER project (.rpp) files for automated testing.
"""
from pathlib import Path
from typing import List, Optional


def generate_rpp(
    output_path: Path,
    audio_file: Path,
    time_selection: Optional[tuple] = None,
    track_name: str = "Test Track"
) -> None:
    """Generate a minimal REAPER project with one audio item."""
    
    # Make paths relative if in same directory
    rel_audio = audio_file.name if audio_file.parent == output_path.parent else str(audio_file)
    
    # Time selection markers
    loop_start = time_selection[0] if time_selection else 0.0
    loop_end = time_selection[1] if time_selection else 0.0
    
    rpp_content = f'''<REAPER_PROJECT 0.1 "7.0" 1234567890
  RIPPLE 0
  GROUPOVERRIDE 0 0 0
  AUTOXFADE 1
  ENVATTACH 3
  POOLEDENVATTACH 0
  MIXERUIFLAGS 11 48
  PEAKGAIN 1
  FEEDBACK 0
  PANLAW 1
  PROJOFFS 0 0 0
  MAXPROJLEN 600 0
  GRID 3199 8 1 8 1 0 0 0
  TIMEMODE 1 5 -1 30 0 0 -1
  VIDEO_CONFIG 0 0 1
  PANMODE 3
  CURSOR 0
  ZOOM 100 0 0
  VZOOMEX 6 0
  USE_REC_CFG 0
  RECMODE 1
  SMPTESYNC 0 30 100 40 1000 300 0 0 1 0 0
  LOOP {"1" if time_selection else "0"}
  LOOPGRAN 0 4
  RECORD_PATH "" ""
  <RECORD_CFG
    ZXZhdxgAAQ==
  >
  <APPLYFX_CFG
  >
  RENDER_FILE ""
  RENDER_PATTERN ""
  RENDER_FMT 0 2 0
  RENDER_1X 0
  RENDER_RANGE 1 0 0 18 1000
  RENDER_RESAMPLE 3 0 1
  RENDER_ADDTOPROJ 0
  RENDER_STEMS 0
  RENDER_DITHER 0
  TIMELOCKMODE 1
  TEMPOENVLOCKMODE 1
  ITEMMIX 0
  DEFPITCHMODE 589824 0
  TAKELANE 1
  SAMPLERATE 44100 0 0
  <TEMPO_ENVEX2
    EGUID {{12345678-1234-1234-1234-123456789012}}
    ACT 0 -1
    VIS 0 1 1
    LANEHEIGHT 0 0
    ARM 0
    DEFSHAPE 1 -1 -1
  >
  PLAYSPEEDENV 0 1 0
  <PROJBAY
  >
  <TRACK {{TRACK-GUID-1}}
    NAME "{track_name}"
    PEAKCOL 16576
    BEAT -1
    AUTOMODE 0
    VOLPAN 1 0 -1 -1 1
    MUTESOLO 0 0 0
    IPHASE 0
    PLAYOFFS 0 1
    ISBUS 0 0
    BUSCOMP 0 0 0 0 0
    SHOWINMIX 1 0.6667 0.5 1 0.5 0 0 0
    FREEMODE 0
    SEL 1
    REC 0 0 1 0 0 0 0 0
    VU 2
    TRACKHEIGHT 0 0 0 0 0 0
    INQ 0 0 0 0.5 100 0 0 100
    NCHAN 2
    FX 1
    TRACKID {{TRACK-GUID-1}}
    PERF 0
    MIDIOUT -1
    MAINSEND 1 0
    <ITEM
      POSITION 0
      SNAPOFFS 0
      LENGTH 10
      LOOP 0
      ALLTAKES 0
      FADEIN 1 0 0 1 0 0 0
      FADEOUT 1 0 0 1 0 0 0
      MUTE 0 0
      SEL 1
      IGUID {{ITEM-GUID-1}}
      IID 1
      NAME "{audio_file.stem}"
      VOLPAN 1 0 1 -1
      SOFFS 0
      PLAYRATE 1 1 0 -1 0 0.0025
      CHANMODE 0
      GUID {{ITEM-GUID-1}}
      <SOURCE WAVE
        FILE "{rel_audio}"
      >
    </ITEM>
  >
'''
    
    # Add time selection if specified
    if time_selection:
        rpp_content += f'  SELECTION {loop_start} {loop_end}\n'
        rpp_content += f'  LOOPSTART {loop_start}\n'
        rpp_content += f'  LOOPEND {loop_end}\n'
    
    rpp_content += '>\n'
    
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(rpp_content)
    
    print(f"Created REAPER project: {output_path}")


if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="Generate REAPER project for testing")
    parser.add_argument("output", type=Path, help="Output .rpp file path")
    parser.add_argument("audio", type=Path, help="Audio file to include")
    parser.add_argument("--time-selection", type=float, nargs=2, 
                       metavar=("START", "END"),
                       help="Time selection start and end (seconds)")
    parser.add_argument("--track-name", default="Test Track",
                       help="Track name")
    
    args = parser.parse_args()
    
    generate_rpp(
        args.output,
        args.audio,
        tuple(args.time_selection) if args.time_selection else None,
        args.track_name
    )