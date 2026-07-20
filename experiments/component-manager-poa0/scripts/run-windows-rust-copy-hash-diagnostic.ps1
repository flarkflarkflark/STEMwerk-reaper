param(
  [Parameter(Mandatory=$true)][string]$Cases
)

$ErrorActionPreference = 'Stop'
$Base = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if ($Cases -ne 'CMN-001,CMN-008') { throw 'Unsupported diagnostic case selection' }
$Binary = Join-Path $Base 'bin/cm-rust.exe'
$Catalog = Join-Path $Base 'fixtures/catalog.json'
$Fixture = Join-Path $Base 'fixtures/artifacts/runtime-fixture.txt'
$ExpectedHash = 'a159ce98c9da7498ff385b4b799e4bac64313de699878e793654929a95e1bab5'

function Write-DiagnosticRecord {
  param([string]$Path, [System.Collections.IDictionary]$Record)
  Add-Content -Encoding utf8NoBOM -LiteralPath $Path -Value ($Record | ConvertTo-Json -Compress -Depth 8)
}

function Quote-PowerShellLiteral([string]$Value) {
  return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-CapturedExternal {
  param(
    [string]$Executable,
    [string[]]$Arguments,
    [string]$StdoutPath,
    [string]$StderrPath
  )
  $Info = [Diagnostics.ProcessStartInfo]::new()
  $Info.FileName = $Executable
  $Info.UseShellExecute = $false
  $Info.RedirectStandardOutput = $true
  $Info.RedirectStandardError = $true
  foreach ($Argument in $Arguments) { [void]$Info.ArgumentList.Add($Argument) }
  $Output = ''; $ErrorOutput = ''; $OutputBytes = [byte[]]@(); $ErrorBytes = [byte[]]@(); $Code = -1
  try {
    $Process = [Diagnostics.Process]::new()
    $Process.StartInfo = $Info
    [void]$Process.Start()
    $OutputBuffer = [IO.MemoryStream]::new()
    $ErrorBuffer = [IO.MemoryStream]::new()
    $Process.StandardOutput.BaseStream.CopyTo($OutputBuffer)
    $Process.StandardError.BaseStream.CopyTo($ErrorBuffer)
    $Process.WaitForExit()
    $Code = $Process.ExitCode
    $OutputBytes = $OutputBuffer.ToArray()
    $ErrorBytes = $ErrorBuffer.ToArray()
    $Output = [Text.Encoding]::UTF8.GetString($OutputBytes)
    $ErrorOutput = [Text.Encoding]::UTF8.GetString($ErrorBytes)
    $OutputBuffer.Dispose()
    $ErrorBuffer.Dispose()
    $Process.Dispose()
  } catch {
    $ErrorOutput = $_.Exception.ToString()
    $ErrorBytes = [Text.Encoding]::UTF8.GetBytes($ErrorOutput)
  }
  [IO.File]::WriteAllBytes("$StdoutPath.raw", $OutputBytes)
  [IO.File]::WriteAllBytes("$StderrPath.raw", $ErrorBytes)
  Set-Content -Encoding utf8NoBOM -LiteralPath $StdoutPath -Value $Output -NoNewline
  Set-Content -Encoding utf8NoBOM -LiteralPath $StderrPath -Value $ErrorOutput -NoNewline
  [ordered]@{
    command = ($Executable + ' ' + (($Arguments | ForEach-Object { '"' + $_.Replace('"','\"') + '"' }) -join ' '))
    exit_code = [int]$Code
    stdout = $Output
    stderr = $ErrorOutput
    stdout_byte_count = $OutputBytes.Length
    stdout_hex = [Convert]::ToHexString($OutputBytes).ToLowerInvariant()
    stderr_byte_count = $ErrorBytes.Length
  }
}

function Add-PrimitiveProbe {
  param(
    [string]$CommandsPath,
    [string]$ProbeDir,
    [string]$Kind,
    [string]$Name,
    [string]$Executable,
    [string[]]$Arguments,
    [bool]$ExpectSuccess,
    [string]$ExpectedOutput = ''
  )
  $Out = Join-Path $ProbeDir "$Name.stdout.log"
  $Err = Join-Path $ProbeDir "$Name.stderr.log"
  Write-DiagnosticRecord $CommandsPath ([ordered]@{event="diag_${Kind}_begin"; probe=$Name; command=$Executable + ' ' + ($Arguments -join ' '); cwd=(Get-Location).Path})
  $Result = Invoke-CapturedExternal $Executable $Arguments $Out $Err
  $Passed = if ($ExpectSuccess) { $Result.exit_code -eq 0 } else { $Result.exit_code -ne 0 }
  $Parsed = $Result.stdout.Trim()
  if ($ExpectedOutput -and $Parsed -ne $ExpectedOutput) { $Passed = $false }
  Write-DiagnosticRecord $CommandsPath ([ordered]@{event="diag_${Kind}_result"; probe=$Name; command=$Result.command; exit_code=$Result.exit_code; stdout=$Result.stdout; stderr=$Result.stderr; stdout_byte_count=$Result.stdout_byte_count; stdout_hex=$Result.stdout_hex; stderr_byte_count=$Result.stderr_byte_count; parsed=$Parsed; expected=$ExpectedOutput; pass=$Passed})
  return $Passed
}

function Write-TreeEvidence {
  param([string]$Root, [string]$TreePath, [string]$HashesPath)
  "relative_path`titem_type`tsize_bytes" | Set-Content -Encoding utf8NoBOM -LiteralPath $TreePath
  "relative_path`tsize_bytes`tsha256" | Set-Content -Encoding utf8NoBOM -LiteralPath $HashesPath
  if (-not (Test-Path -LiteralPath $Root)) { return }
  Get-ChildItem -Force -Recurse -LiteralPath $Root | Sort-Object FullName | ForEach-Object {
    $Relative = [IO.Path]::GetRelativePath($Root, $_.FullName)
    $Type = if ($_.PSIsContainer) { 'directory' } else { 'file' }
    $Size = if ($_.PSIsContainer) { 0 } else { $_.Length }
    "$Relative`t$Type`t$Size" | Add-Content -Encoding utf8NoBOM -LiteralPath $TreePath
    if (-not $_.PSIsContainer) {
      $Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
      "$Relative`t$Size`t$Hash" | Add-Content -Encoding utf8NoBOM -LiteralPath $HashesPath
    }
  }
}

function Run-CaseDiagnostic {
  param([string]$CaseId)
  $Artifact = Join-Path $Base "reports/results/windows-rust-copy-hash-diagnostic-$CaseId"
  $CaseRoot = Join-Path $Base ("poa-roots/diagnostic-{0}-{1}" -f $CaseId, [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force $Artifact, $CaseRoot | Out-Null
  $Commands = Join-Path $Artifact 'commands.jsonl'
  $ProbeDir = Join-Path $Artifact 'probes'
  New-Item -ItemType Directory -Force $ProbeDir | Out-Null

  $SourceForward = $Fixture.Replace('\','/')
  $SourceBackward = $Fixture.Replace('/','\')
  $Stage = Join-Path $CaseRoot 'probe-stage'
  $SpaceDir = Join-Path $CaseRoot 'space path'
  $UnicodeDir = Join-Path $CaseRoot 'unicode-Δ'
  New-Item -ItemType Directory -Force $Stage, $SpaceDir, $UnicodeDir | Out-Null
  $SourceSize = (Get-Item -LiteralPath $Fixture).Length
  $SourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Fixture).Hash.ToLowerInvariant()

  $CopyPass = 0; $CopyTotal = 0; $HashPass = 0; $HashTotal = 0
  $CopyTargets = @(
    @{name='copy-forward'; path=(Join-Path $Stage 'forward.txt'); source=$SourceForward; success=$true},
    @{name='copy-backslash'; path=(Join-Path $Stage 'backslash.txt'); source=$SourceBackward; success=$true},
    @{name='copy-space'; path=(Join-Path $SpaceDir 'fixture copy.txt'); source=$Fixture; success=$true},
    @{name='copy-unicode'; path=(Join-Path $UnicodeDir 'fixture-Δ.txt'); source=$Fixture; success=$true},
    @{name='copy-invalid-parent'; path=(Join-Path $CaseRoot 'missing-parent/fixture.txt'); source=$Fixture; success=$false}
  )
  foreach ($Probe in $CopyTargets) {
    $CopyTotal++
    $Command = "Copy-Item -LiteralPath $(Quote-PowerShellLiteral $Probe.source) -Destination $(Quote-PowerShellLiteral $Probe.path) -Force"
    if (Add-PrimitiveProbe $Commands $ProbeDir copy $Probe.name powershell @('-NoProfile','-Command',$Command) $Probe.success) { $CopyPass++ }
  }

  $HashPaths = @(
    @{name='hash-forward'; path=$SourceForward; success=$true},
    @{name='hash-backslash'; path=$SourceBackward; success=$true},
    @{name='hash-space'; path=(Join-Path $SpaceDir 'fixture copy.txt'); success=$true},
    @{name='hash-unicode'; path=(Join-Path $UnicodeDir 'fixture-Δ.txt'); success=$true},
    @{name='hash-missing'; path=(Join-Path $CaseRoot 'absent.txt'); success=$false}
  )
  foreach ($Probe in $HashPaths) {
    $HashTotal++
    $Command = "(Get-FileHash -Algorithm SHA256 -LiteralPath $(Quote-PowerShellLiteral $Probe.path)).Hash.ToLower()"
    $Expected = if ($Probe.success) { $ExpectedHash } else { '' }
    if (Add-PrimitiveProbe $Commands $ProbeDir hash $Probe.name powershell @('-NoProfile','-Command',$Command) $Probe.success $Expected) { $HashPass++ }
  }
  $HashTotal++
  $WithNewline = "$ExpectedHash`r`n"
  $WithoutNewline = $ExpectedHash
  $ParserPass = ($WithNewline.Trim() -eq $ExpectedHash -and $WithoutNewline.Trim() -eq $ExpectedHash)
  if ($ParserPass) { $HashPass++ }
  Write-DiagnosticRecord $Commands ([ordered]@{event='diag_hash_result';probe='hash-newline-parser';exit_code=0;stdout_with_newline=$WithNewline;stdout_without_newline=$WithoutNewline;parsed_with_newline=$WithNewline.Trim();parsed_without_newline=$WithoutNewline.Trim();expected=$ExpectedHash;pass=$ParserPass})

  $Stdout = Join-Path $Artifact 'stdout.log'
  $Stderr = Join-Path $Artifact 'stderr.log'
  $Arguments = @('install','--root',$CaseRoot,'--catalog',$Catalog)
  if ($CaseId -eq 'CMN-008') {
    $PreOut = Join-Path $Artifact 'prerequisite.stdout.log'
    $PreErr = Join-Path $Artifact 'prerequisite.stderr.log'
    Write-DiagnosticRecord $Commands ([ordered]@{event='diag_failure_context';phase='prerequisite_begin';case_id=$CaseId;binary=$Binary;arguments=$Arguments;root=$CaseRoot;catalog=$Catalog})
    $Run = Invoke-CapturedExternal $Binary $Arguments $PreOut $PreErr
    if ($Run.exit_code -eq 0) {
      $env:POA_FAULT = 'kill_after_active_swap'
      try { $Run = Invoke-CapturedExternal $Binary $Arguments $Stdout $Stderr } finally { Remove-Item Env:POA_FAULT -ErrorAction SilentlyContinue }
    } else {
      Copy-Item -LiteralPath $PreOut -Destination $Stdout
      Copy-Item -LiteralPath $PreErr -Destination $Stderr
    }
  } else {
    $Run = Invoke-CapturedExternal $Binary $Arguments $Stdout $Stderr
  }
  Copy-Item -LiteralPath $Stdout -Destination (Join-Path $Artifact 'jsonl.log')

  $Journal = Join-Path $CaseRoot 'state/journal/operations.jsonl'
  $Active = Join-Path $CaseRoot 'state/active'
  $JournalFinal = if (Test-Path -LiteralPath $Journal) { (Get-Content -LiteralPath $Journal | Select-Object -Last 1) } else { 'missing' }
  $ActiveValue = if (Test-Path -LiteralPath $Active) { Get-Content -Raw -LiteralPath $Active } else { 'missing' }
  $JsonObjects = @()
  Get-Content -LiteralPath $Stdout -ErrorAction SilentlyContinue | ForEach-Object { try { $JsonObjects += ($_ | ConvertFrom-Json -ErrorAction Stop) } catch {} }
  $Envelope = $JsonObjects | Where-Object { $_.PSObject.Properties.Name -contains 'ok' } | Select-Object -Last 1
  $ErrorCode = if ($Envelope -and $Envelope.error_code) { [string]$Envelope.error_code } else { '' }
  $GenerationDirs = @(Get-ChildItem -Directory -LiteralPath (Join-Path $CaseRoot 'generations') -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.tmp' })
  $HalfActivated = ($ActiveValue -eq 'missing' -and $GenerationDirs.Count -gt 0)
  Write-DiagnosticRecord $Commands ([ordered]@{event='diag_failure_context';phase='process_result';case_id=$CaseId;binary=$Binary;arguments=$Arguments;exit_code=$Run.exit_code;stdout=$Run.stdout;stderr=$Run.stderr;source_harness_path=$Fixture;source_native_forward=$SourceForward;source_native_backslash=$SourceBackward;source_exists=(Test-Path -LiteralPath $Fixture);source_type='file';source_size=$SourceSize;source_sha256=$SourceHash;case_root=$CaseRoot;case_root_parent_exists=(Test-Path -LiteralPath (Split-Path -Parent $CaseRoot));result_envelope_present=[bool]$Envelope;error_code=$ErrorCode;journal_final=$JournalFinal;active_generation=$ActiveValue;half_activated_generation=$HalfActivated})

  Write-TreeEvidence $CaseRoot (Join-Path $Artifact 'tree.tsv') (Join-Path $Artifact 'hashes.tsv')
  $PowerShellCommand = Get-Command powershell -ErrorAction SilentlyContinue
  $PowerShellLookup = if ($PowerShellCommand) { $PowerShellCommand.Source } else { 'missing' }
  $PowerShellVersion = if ($PowerShellCommand) { & $PowerShellCommand.Source -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' } else { 'unavailable' }
  @(
    "cwd=$((Get-Location).Path)",
    "path=$env:PATH",
    "pathext=$env:PATHEXT",
    "powershell_lookup=$PowerShellLookup",
    "powershell_version=$PowerShellVersion",
    "pwsh_version=$($PSVersionTable.PSVersion.ToString())",
    "rust_binary=$Binary",
    "rust_binary_sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $Binary).Hash.ToLowerInvariant())",
    "filesystem=$((Get-Volume -DriveLetter ([IO.Path]::GetPathRoot($CaseRoot).Substring(0,1))).FileSystem)",
    "same_volume=$([IO.Path]::GetPathRoot($Fixture) -eq [IO.Path]::GetPathRoot($CaseRoot))"
  ) | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $Artifact 'environment.txt')
  [ordered]@{
    schema_version=1; case_id=$CaseId; process_exit_code=$Run.exit_code
    source_exists=(Test-Path -LiteralPath $Fixture); source_size=$SourceSize; source_sha256=$SourceHash; expected_sha256=$ExpectedHash
    copy_primitive_probes="$CopyPass/$CopyTotal"; hash_primitive_probes="$HashPass/$HashTotal"
    space_path_probe=if ((Test-Path -LiteralPath (Join-Path $SpaceDir 'fixture copy.txt'))) {'PASS'} else {'FAIL'}
    unicode_path_probe=if ((Test-Path -LiteralPath (Join-Path $UnicodeDir 'fixture-Δ.txt'))) {'PASS'} else {'FAIL'}
    missing_file_probe=if (-not (Test-Path -LiteralPath (Join-Path $CaseRoot 'absent.txt'))) {'PASS'} else {'FAIL'}
    invalid_parent_probe=if (-not (Test-Path -LiteralPath (Join-Path $CaseRoot 'missing-parent/fixture.txt'))) {'PASS'} else {'FAIL'}
    result_envelope_present=[bool]$Envelope; error_code=$ErrorCode; underlying_stderr_visible=([bool]$Run.stderr)
    journal_final_state=$JournalFinal; active_generation_after_failure=$ActiveValue; half_activated_generation_present=$HalfActivated
    case_root_preserved=$true
  } | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $Artifact 'summary.json')
  Copy-Item -Recurse -Force -LiteralPath $CaseRoot -Destination (Join-Path $Artifact 'case-root')
}

Set-Location $Base
foreach ($CaseId in $Cases.Split(',')) { Run-CaseDiagnostic $CaseId }
