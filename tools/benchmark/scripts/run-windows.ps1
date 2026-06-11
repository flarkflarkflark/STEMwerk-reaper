$ErrorActionPreference = "Stop"

$BenchDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$PortableRoot = if ($env:STEMWERK_BENCHMARK_ROOT) {
    $env:STEMWERK_BENCHMARK_ROOT
} else {
    $BenchDir
}
$Preset = if ($env:STEMWERK_BENCHMARK_PRESET) { $env:STEMWERK_BENCHMARK_PRESET } else { "smoke" }
$Runner = Join-Path $BenchDir "stemwerk_benchmark.py"
$PortableRunner = Join-Path $BenchDir "runner\stemwerk_benchmark.py"
if (Test-Path $PortableRunner) {
    $Runner = $PortableRunner
}

python $Runner `
    --input-dir (Join-Path $PortableRoot "audio") `
    --preset (Join-Path $BenchDir "presets\$Preset.json") `
    --output-dir (Join-Path $PortableRoot "results") `
    @args
exit $LASTEXITCODE
