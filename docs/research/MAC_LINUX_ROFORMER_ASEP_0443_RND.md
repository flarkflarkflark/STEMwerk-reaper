# RoFormer / audio-separator 0.44.3 platform R&D (juli 2026)

## Conclusie

ASEP_0443_PLATFORM_UPGRADE_PROMISING. Alle eerdere "avoid"-labels bleken
instrument-artefacten, geen eigenschappen van model, hardware of architectuur:

- RoFormer-MPS "avoid" -> torch 2.5.1-artefact (macOS-pin uit 2.2.1.1-era)
- MelBand 1.6G MPS OOM -> torch 2.5.1 geheugenbeheer; PASS op moderne torch
- Demucs safeload-crash -> audio-separator 0.23.0-artefact; opgelost in 0.44.3
- Viperx Linux-fail -> Python 3.14 + beartype 0.18.5 typehint-issue
  (BeartypeDecorHintNonpepException op BSRoformer.__init__ stft_window_fn)

## Bewezen matrix (versie-gescoped)

macOS (Apple Silicon, audio-separator 0.44.3 + moderne torch):
  Demucs PASS, RoFormer/Viperx PASS, PR #68-procespath PASS op device=mps.
  Python-versie: NIET GEVONDEN in beschikbare rapporten — menselijke input nodig.

Linux ROCm (RX 9070, audio-separator 0.44.3, Python 3.12.13,
torch/torchaudio 2.10.0+rocm7.0, onnxruntime 1.27.0, beartype 0.18.5):
  htdemucs_ft PASS (30s elapsed / 26s separation), DKS via echt entrypoint
  PASS (64s, 6 kit-parts, rocm->cuda:0), Viperx PASS (33s elapsed /
  00:00:26 separation).

Python 3.14.6: known-bad voor Viperx (beartype). Python-versie is
pin-dimensie #5.

Instructie macOS-Python-veld:

- Zoek alleen in bestaande lokale docs/logs/rapporten.
- Niet infereren. Niet gokken. Niet uit Linux afleiden. Niet uit
  systeem-Python afleiden.
- Als geen exacte macOS runtime-Python gevonden wordt, schrijf letterlijk:
  "NIET GEVONDEN in beschikbare rapporten — menselijke input nodig."

## Timing

Viperx ROCm 0.44.3 cold: 33s elapsed / 26s separation. Oude
0.23.0-baseline: ~19s/14s. Warm timing niet gemeten: throwaway-runtime
verloren bij cleanup-incident. Herbeoordelen tijdens pins-branch-smokes
(die bouwen toch een verse runtime). Eerdere Errno 28 definitief
verklaard: /tmp is 32G tmpfs.

## DKS catalogus-rename (actiepunt pins-branch)

0.44.3-catalogus: MDX23C-DrumSep-aufr33-jarredou.ckpt +
config_drumsep_mdx23c.yaml. Oude STEMwerk-naming:
aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt/.yaml.
Sync vereist in: stemwerk_drumsep_process.py aliases, models.json
runtime_managed_assets, fresh-install gedrag. Drie testcases: oude cache /
verse install / gemengde upgrade-state (de "echte gebruiker"-case).

## Cleanup-incident

Warm timing niet gemeten omdat de throwaway-runtime is verwijderd tijdens
cleanup (find zonder -mindepth 1 matchte de parent-directory; exact-match
KEEP-check ving de ancestor niet). Alleen wegwerp-artefacten verloren;
shared runtime, model-cache, repo en vastgelegde resultaten onaangetast.
Leidde tot strengere conventie, zie PROMPT_SAFETY_CONVENTIONS.md.

## Pin-matrix voor de pins-branch (5 dimensies per platform)

| Platform | Python | audio-separator | torch/torchaudio | onnxruntime | compat-notes |
| --- | --- | --- | --- | --- | --- |
| Linux ROCm | 3.12.13 | 0.44.3 | 2.10.0+rocm7.0 | 1.27.0 | beartype 0.18.5; 3.14 known-bad |
| macOS | NIET GEVONDEN in beschikbare rapporten — menselijke input nodig. | 0.44.3 | [uit Fase A-rapport] | [idem] | idem beartype-note |
| Windows | open | open | open | open | open kolom |

(torchvision alleen pinnen als daadwerkelijk vereist — verifieer.)
