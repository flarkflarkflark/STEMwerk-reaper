# STEMwerk Theming Plan — 2.2.2-dev

Working notes for phase-3 theming work. The semantic theme architecture and `ACTIVE_THEME` resolver already exist. Pilot themes `studio`, `aurora`, `copper` exist with distinct color palettes and style values (cornerRadius, borderWeight, shadowStrength, fxIntensity).

## Current diagnosis

Themes still feel too similar despite distinct color data and distinct style-token values. Root cause: the glossy finish applied by `drawGlossyPill` and `drawGlossyRect` (highlight gradient, specular band, dark gradient bottom, inner rim) is not theme-aware. It overrides theme character by imposing the same glossy sheen across all themes. Theme-specific cornerRadius (studio=4, aurora=12, copper=8) is partly visible but dominated by the consistent gloss finish.

Secondary cause: `shadowStrength` values (studio=0.03, aurora=0.18, copper=0.12) combined with `drawThemeShadow`'s alpha formula (`baseAlpha = max(0.015, shadowStrength * 0.22)`) produce near-invisible shadows across all themes. The spread needs to be widened significantly before differences become perceptible.

## Pass A — gloss per theme (safe, ready to execute)

Introduce a new `glossStrength` style token per theme.

Values:
- studio dark + light: `glossStrength = 0.2` (near-matte, console-like)
- aurora dark + light: `glossStrength = 1.0` (full glossy sheen)
- copper dark + light: `glossStrength = 0.65` (subtle sheen, tactile)
- Default in `deriveSemanticTheme`: `glossStrength = 1.0` (preserves existing behavior for classic/ember/ice/mono presets which have no style block)

Add a getter `getThemeGlossStrength(fallback)` in `STEMwerk.lua`, after `getThemeBorderWeight`. Implementation:

````lua
local function getThemeGlossStrength(fallback)
    local value = getThemeStyleNumber("glossStrength", fallback or 1) or 1
    if value < 0 then return 0 end
    if value > 1.5 then return 1.5 end
    return value
end
````

In `drawGlossyPill` (around line 8378), read `local gloss = getThemeGlossStrength(1)` after the existing `local radius = getThemeRadius(...)` line. Multiply the alpha argument by `gloss` on four specific `gfx.set(...)` calls:

- The highlight-gradient loop: `0.25 * t * baseA` → `0.25 * t * baseA * gloss`
- The white specular band loop: `0.12 * t * baseA` → `0.12 * t * baseA * gloss`
- The bottom shadow-gradient loop: `0.18 * t * baseA` → `0.18 * t * baseA * gloss`
- The inner dark rim loop: `0.2 * baseA` → `0.2 * baseA * gloss`

Do not modify the `drawThemeShadow(...)` call (shadow is a separate token).
Do not modify the body-color fill call.

Same changes in `drawGlossyRect` (around line 8446). Same four alpha-multiplier insertions.

Classic/ember/ice/mono must render identically to before (glossStrength defaults to 1.0 → no-op).

## Pass B — shadow spread (only after Pass A lands)

Bump `shadowStrength` values to bring them above perceptual threshold:

- studio: 0.03 → **0.0** (no shadow; `drawThemeShadow` early-returns on `<= 0.001`)
- aurora: 0.18 → **0.38** (visible cyan-tinted soft shadow via `getThemeShadowColor` which already mixes accent)
- copper: 0.12 → **0.22** (visible amber-tinted medium shadow)

Risk: extra shadow passes may cost FPS on progress and result windows (many simultaneous buttons). Monitor those screens first. If aurora feels over-shadowed at 0.38, tune down to 0.30.

## Pass C — later, optional

- Theme-aware button padding (within ±2px) once primitives are extracted.
- Tooltip-specific shadow tint that reinforces theme character (tooltips currently use `drawThemeSurfaceBox` which already uses `getThemeShadowColor`, may not need changes).
- Additional themes once the current three feel genuinely distinct:
  - `noir`: near-monochrome, high-contrast, cornerRadius=0-1, severe version of studio
  - `forest`: deep desaturated green, medium round, long-session calm
  - `soft`: large cornerRadius, no hard borders, elevation-only separation (architecture stress-test)

## Audio-Reactive Guardrails (future background/art theming)

Dynamic background/artwork FX are partly audio-reactive and must stay that way.

Theme work may affect:
- color bias
- hue/saturation modulation
- opacity bias
- background mood

Theme work must not affect:
- motion
- pulse behavior
- density
- beat emphasis
- animation timing
- any other audio-driven behavior

Future resolution order for artwork theming:
1. base artwork color
2. audio-reactive behavior modulation
3. theme color/alpha modulation
4. visibility/contrast guardrails

Core rule: theme shapes mood, audio drives behavior.

## Out of scope for theming work

- `textPrimary` stays near-white in all themes (readability non-negotiable)
- Semantic `success` / `warning` / error colors — signals, not decoration
- Record/arm/solo/mute state colors — DAW muscle memory
- Waveform / VU / spectrum / level meter colors — functional signal
- Focus ring visibility (must remain obvious in every theme)
- `layoutDensity`, font family, line-height — structural, not chromatic

## Execution order recommendation

1. Finish primitives extraction into `STEMwerk_UI_Draw.lua` first (separate refactor work)
2. Pass A (gloss per theme) — small diff, low risk, big visual payoff
3. Evaluate for a week on the dev branch with real use
4. Pass B (shadow bump) — only if Pass A lands cleanly
5. Pass C items deferred to later releases
