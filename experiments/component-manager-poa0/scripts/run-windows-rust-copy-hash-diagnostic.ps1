param(
  [Parameter(Mandatory=$true)][string]$Cases
)

$ErrorActionPreference = 'Stop'
$Base = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if ($Cases -notin @('CMN-001,CMN-008', 'CMN-008')) { throw 'Unsupported diagnostic case selection' }
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
  $Output = ''; $ErrorOutput = ''; $OutputBytes = [byte[]]@(); $ErrorBytes = [byte[]]@(); $Code = -1; $ProcessId = 0; $HasExited = $false
  try {
    $Process = [Diagnostics.Process]::new()
    $Process.StartInfo = $Info
    [void]$Process.Start()
    $ProcessId = $Process.Id
    $OutputBuffer = [IO.MemoryStream]::new()
    $ErrorBuffer = [IO.MemoryStream]::new()
    $Process.StandardOutput.BaseStream.CopyTo($OutputBuffer)
    $Process.StandardError.BaseStream.CopyTo($ErrorBuffer)
    $Process.WaitForExit()
    $HasExited = $Process.HasExited
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
    process_id = $ProcessId
    has_exited = $HasExited
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

function Save-RecoveryState {
  param([string]$Root, [string]$Destination)
  New-Item -ItemType Directory -Force $Destination | Out-Null
  $State = Join-Path $Root 'state'
  $Generations = Join-Path $Root 'generations'
  foreach ($Relative in @('state/active','state/active.tmp','state/journal/operations.jsonl','state/state.db','state/state.db-wal','state/state.db-shm')) {
    $Source = Join-Path $Root $Relative
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
      $Target = Join-Path $Destination $Relative
      New-Item -ItemType Directory -Force (Split-Path -Parent $Target) | Out-Null
      Copy-Item -Force -LiteralPath $Source -Destination $Target
    }
  }
  if (Test-Path -LiteralPath $Generations -PathType Container) {
    Copy-Item -Recurse -Force -LiteralPath $Generations -Destination (Join-Path $Destination 'generationtree')
  }
  Write-TreeEvidence $Root (Join-Path $Destination 'tree.tsv') (Join-Path $Destination 'hashes.tsv')
}

function Invoke-CMN008RecoveryValidation {
  param(
    [string]$Root,
    [string]$Artifact,
    [System.Collections.IDictionary]$KillRun,
    [string]$PreKillGeneration
  )
  New-Item -ItemType Directory -Force $Artifact | Out-Null
  $Timeline = Join-Path $Artifact 'timeline.jsonl'
  $Errors = Join-Path $Artifact 'errors.tsv'
  "category`tdetail" | Set-Content -Encoding utf8NoBOM -LiteralPath $Errors
  $Failures = [Collections.Generic.List[object]]::new()
  $Require = {
    param([bool]$Condition, [string]$Category, [string]$Detail)
    if (-not $Condition) {
      $Failures.Add([pscustomobject]@{category=$Category;detail=$Detail})
      "$Category`t$Detail" | Add-Content -Encoding utf8NoBOM -LiteralPath $Errors
    }
  }

  Save-RecoveryState $Root (Join-Path $Artifact 'post-kill')
  Write-DiagnosticRecord $Timeline ([ordered]@{schema_version=1;event='post_kill_state_captured';root=$Root;process_id=$KillRun.process_id;exit_code=$KillRun.exit_code;child_terminated=$KillRun.has_exited})
  & $Require ([bool]$KillRun.has_exited) 'CHILD_NOT_TERMINATED' "pid=$($KillRun.process_id)"
  & $Require ($KillRun.exit_code -ne 0) 'ORCHESTRATION_FAILURE' "injected kill exited $($KillRun.exit_code), expected non-zero"
  & $Require (Test-Path -LiteralPath $Root -PathType Container) 'ORCHESTRATION_FAILURE' 'case root missing after kill'
  & $Require (Test-Path -LiteralPath (Join-Path $Root 'state') -PathType Container) 'ORCHESTRATION_FAILURE' 'state root missing after kill'
  $PostKillSelector = $null
  try { $PostKillSelector = Get-Content -Raw -LiteralPath (Join-Path $Root 'state/active') | ConvertFrom-Json -ErrorAction Stop } catch {}
  $PostKillGeneration = if ($PostKillSelector) { [string]$PostKillSelector.generation_id } else { '' }
  & $Require ($PostKillGeneration -match '^gen-[0-9]+$') 'SELECTOR_INVALID_AFTER_RECOVERY' 'post-kill selector is missing or malformed'
  & $Require ($PostKillGeneration -ne $PreKillGeneration) 'ORCHESTRATION_FAILURE' "kill point not reached: pre=$PreKillGeneration post=$PostKillGeneration"
  if ($Failures.Count -gt 0) {
    [ordered]@{schema_version=1;case_id='CMN-008';result='FAIL';pre_kill_generation=$PreKillGeneration;post_kill_generation=$PostKillGeneration;kill_exit_code=$KillRun.exit_code;child_terminated=$KillRun.has_exited;recovery_invoked=$false;failures=$Failures} | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $Artifact 'summary.json')
    throw "CMN-008 pre-recovery gate failed: $($Failures[0].category): $($Failures[0].detail)"
  }

  $RecoverStdout = Join-Path $Artifact 'recover-stdout.log'
  $RecoverStderr = Join-Path $Artifact 'recover-stderr.log'
  $RecoverArguments = @('recover','--root',$Root)
  Write-DiagnosticRecord $Timeline ([ordered]@{schema_version=1;event='recover_begin';binary=$Binary;arguments=$RecoverArguments;root=$Root})
  $RecoverRun = Invoke-CapturedExternal $Binary $RecoverArguments $RecoverStdout $RecoverStderr
  Write-DiagnosticRecord $Timeline ([ordered]@{schema_version=1;event='recover_result';exit_code=$RecoverRun.exit_code;root=$Root})
  & $Require ($RecoverRun.exit_code -eq 0) 'RECOVER_NONZERO_EXIT' "exit=$($RecoverRun.exit_code); stderr=$($RecoverRun.stderr)"

  $RecoverObjects = @()
  Get-Content -LiteralPath $RecoverStdout -ErrorAction SilentlyContinue | ForEach-Object { try { $RecoverObjects += ($_ | ConvertFrom-Json -ErrorAction Stop) } catch {} }
  $RecoverEnvelope = $RecoverObjects | Where-Object { $_.PSObject.Properties.Name -contains 'ok' } | Select-Object -Last 1
  if ($RecoverEnvelope) { $RecoverEnvelope | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $Artifact 'recover-result.json') }
  else { '{}' | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $Artifact 'recover-result.json') }
  & $Require ([bool]$RecoverEnvelope) 'RECOVER_RESULT_INVALID' 'structured result envelope missing'
  if ($RecoverEnvelope) {
    & $Require ([bool]$RecoverEnvelope.ok) 'RECOVER_RESULT_INVALID' "ok=$($RecoverEnvelope.ok)"
    & $Require ($RecoverEnvelope.state -eq 'rebuilt') 'RECOVER_RESULT_INVALID' "state=$($RecoverEnvelope.state)"
  }

  $ActivePath = Join-Path $Root 'state/active'
  $Selector = $null
  try { $Selector = Get-Content -Raw -LiteralPath $ActivePath | ConvertFrom-Json -ErrorAction Stop } catch {}
  $RecoveredGeneration = if ($Selector) { [string]$Selector.generation_id } else { '' }
  $GenerationPath = Join-Path $Root "generations/$RecoveredGeneration"
  $GenerationManifestPath = Join-Path $GenerationPath 'generation.json'
  $SelectorValid = [bool]$Selector -and $RecoveredGeneration -match '^gen-[0-9]+$'
  & $Require $SelectorValid 'SELECTOR_INVALID_AFTER_RECOVERY' 'selector is missing or malformed'
  & $Require ($RecoveredGeneration -eq $PostKillGeneration) 'SELECTOR_INVALID_AFTER_RECOVERY' "post_kill=$PostKillGeneration recovered=$RecoveredGeneration"
  & $Require (Test-Path -LiteralPath $GenerationPath -PathType Container) 'SELECTOR_POINTS_TO_MISSING_GENERATION' "generation=$RecoveredGeneration"
  [ordered]@{schema_version=1;valid=$SelectorValid;generation_id=$RecoveredGeneration;generation_exists=(Test-Path -LiteralPath $GenerationPath -PathType Container)} | ConvertTo-Json | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $Artifact 'selector-validation.json')

  $Manifest = $null
  try { $Manifest = Get-Content -Raw -LiteralPath $GenerationManifestPath | ConvertFrom-Json -ErrorAction Stop } catch {}
  $ExpectedComponents = @('model.fixture@1.0.0','runtime.fixture@1.0.0')
  $ManifestValid = [bool]$Manifest -and $Manifest.generation_id -eq $RecoveredGeneration -and @($Manifest.components).Count -eq 2 -and (@($Manifest.components | Sort-Object) -join ',') -eq (($ExpectedComponents | Sort-Object) -join ',')
  & $Require $ManifestValid 'MANIFEST_INVALID_AFTER_RECOVERY' "generation=$RecoveredGeneration"

  $ReceiptResults = [Collections.Generic.List[object]]::new()
  foreach ($Component in @(@{id='model.fixture';artifact='model-fixture.txt'},@{id='runtime.fixture';artifact='runtime-fixture.txt'})) {
    $ReceiptPath = Join-Path $Root "store/components/$($Component.id)/1.0.0/.stemwerk-component.json"
    $ArtifactPath = Join-Path $Root "store/components/$($Component.id)/1.0.0/$($Component.artifact)"
    $Receipt = $null
    try { $Receipt = Get-Content -Raw -LiteralPath $ReceiptPath | ConvertFrom-Json -ErrorAction Stop } catch {}
    $ArtifactHash = if (Test-Path -LiteralPath $ArtifactPath -PathType Leaf) { (Get-FileHash -Algorithm SHA256 -LiteralPath $ArtifactPath).Hash.ToLowerInvariant() } else { '' }
    $ReceiptHash = if (Test-Path -LiteralPath $ReceiptPath -PathType Leaf) { (Get-FileHash -Algorithm SHA256 -LiteralPath $ReceiptPath).Hash.ToLowerInvariant() } else { '' }
    $Valid = [bool]$Receipt -and $Receipt.component_id -eq $Component.id -and $Receipt.artifact_sha256 -eq $ArtifactHash -and $Manifest.component_receipt_hashes.($Component.id) -eq $ReceiptHash
    $ReceiptResults.Add([pscustomobject]@{component_id=$Component.id;valid=$Valid;receipt_hash=$ReceiptHash;artifact_hash=$ArtifactHash})
    & $Require $Valid 'RECEIPTS_INVALID_AFTER_RECOVERY' "component=$($Component.id)"
  }
  $ReceiptResults | ConvertTo-Json | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $Artifact 'generation-validation.json')

  $SqliteDir = Join-Path $Artifact 'post-recovery'
  New-Item -ItemType Directory -Force $SqliteDir | Out-Null
  $Database = Join-Path $Root 'state/state.db'
  $GenerationQuery = Invoke-CapturedExternal $env:STEMWERK_POA0_SQLITE_EXE @('-json',$Database,'SELECT generation_id,active,previous_generation FROM generations ORDER BY generation_id;') (Join-Path $SqliteDir 'sqlite-generations.json') (Join-Path $SqliteDir 'sqlite-generations.stderr.log')
  $InventoryQuery = Invoke-CapturedExternal $env:STEMWERK_POA0_SQLITE_EXE @('-json',$Database,'SELECT component_id,version,receipt_hash FROM inventory ORDER BY component_id;') (Join-Path $SqliteDir 'sqlite-inventory.json') (Join-Path $SqliteDir 'sqlite-inventory.stderr.log')
  $GenerationRows = @(); $InventoryRows = @()
  try { $GenerationRows = @(Get-Content -Raw -LiteralPath (Join-Path $SqliteDir 'sqlite-generations.json') | ConvertFrom-Json -ErrorAction Stop) } catch {}
  try { $InventoryRows = @(Get-Content -Raw -LiteralPath (Join-Path $SqliteDir 'sqlite-inventory.json') | ConvertFrom-Json -ErrorAction Stop) } catch {}
  $InventoryHashesValid = $InventoryRows.Count -eq 2
  foreach ($Row in $InventoryRows) {
    $ExpectedReceipt = $ReceiptResults | Where-Object { $_.component_id -eq $Row.component_id } | Select-Object -First 1
    if (-not $ExpectedReceipt -or $Row.version -ne '1.0.0' -or $Row.receipt_hash -ne $ExpectedReceipt.receipt_hash) { $InventoryHashesValid = $false }
  }
  $SqliteValid = $GenerationQuery.exit_code -eq 0 -and $InventoryQuery.exit_code -eq 0 -and $GenerationRows.Count -eq 1 -and $GenerationRows[0].generation_id -eq $RecoveredGeneration -and [int]$GenerationRows[0].active -eq 1 -and $InventoryHashesValid
  & $Require $SqliteValid 'SQLITE_STATE_MISMATCH' "generation_rows=$($GenerationRows.Count); inventory_rows=$($InventoryRows.Count); active=$RecoveredGeneration"
  [ordered]@{schema_version=1;valid=$SqliteValid;generation_rows=$GenerationRows;inventory_rows=$InventoryRows} | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $Artifact 'sqlite-validation.json')

  $JournalPath = Join-Path $Root 'state/journal/operations.jsonl'
  $JournalObjects = @()
  Get-Content -LiteralPath $JournalPath -ErrorAction SilentlyContinue | ForEach-Object { try { $JournalObjects += ($_ | ConvertFrom-Json -ErrorAction Stop) } catch {} }
  $JournalFinal = $JournalObjects | Select-Object -Last 1
  $JournalFinalEvent = $JournalObjects | Where-Object { $_.PSObject.Properties.Name -contains 'event' } | Select-Object -Last 1
  $JournalValid = [bool]$JournalFinalEvent -and $JournalFinalEvent.event -eq 'op_completed' -and $RecoverEnvelope -and $JournalFinal.op_id -eq $RecoverEnvelope.op_id -and $JournalFinal.state -eq 'rebuilt' -and [bool]$JournalFinal.ok
  & $Require $JournalValid 'JOURNAL_STATE_MISMATCH' "final_event=$($JournalFinalEvent.event); final_state=$($JournalFinal.state)"
  [ordered]@{schema_version=1;valid=$JournalValid;final_event=$JournalFinalEvent;final_result=$JournalFinal} | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $Artifact 'journal-validation.json')

  $GenerationDirs = @(Get-ChildItem -Directory -LiteralPath (Join-Path $Root 'generations') -ErrorAction SilentlyContinue)
  $Incomplete = @($GenerationDirs | Where-Object { -not (Test-Path -LiteralPath (Join-Path $_.FullName 'generation.json') -PathType Leaf) })
  $MixedReferences = if ($ManifestValid -and (@($Manifest.components | Select-Object -Unique).Count -eq 2)) { 0 } else { 1 }
  $LeaseFiles = @(Get-ChildItem -File -LiteralPath (Join-Path $Root 'state/leases') -ErrorAction SilentlyContinue)
  $TempSelectorActive = Test-Path -LiteralPath (Join-Path $Root 'state/active.tmp') -PathType Leaf
  & $Require ($Incomplete.Count -eq 0) 'INCOMPLETE_GENERATION_NOT_HANDLED' "count=$($Incomplete.Count)"
  & $Require ($MixedReferences -eq 0) 'MIXED_GENERATION_VISIBLE' "count=$MixedReferences"
  & $Require ($LeaseFiles.Count -eq 0) 'RECOVER_RESULT_INVALID' "open_leases=$($LeaseFiles.Count)"
  & $Require (-not $TempSelectorActive) 'SELECTOR_INVALID_AFTER_RECOVERY' 'stale active.tmp remains'
  [ordered]@{schema_version=1;valid=($ManifestValid -and $ReceiptResults.valid -notcontains $false);generation_id=$RecoveredGeneration;manifest_valid=$ManifestValid;receipts=$ReceiptResults;incomplete_generation_count=$Incomplete.Count;mixed_generation_references=$MixedReferences;open_lease_count=$LeaseFiles.Count;temp_selector_present=$TempSelectorActive} | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $Artifact 'generation-validation.json')

  Save-RecoveryState $Root (Join-Path $Artifact 'post-recovery')
  Write-TreeEvidence $Root (Join-Path $Artifact 'tree.tsv') (Join-Path $Artifact 'hashes.tsv')
  $Passed = $Failures.Count -eq 0
  [ordered]@{schema_version=1;case_id='CMN-008';result=if($Passed){'PASS'}else{'FAIL'};same_state_root=$true;pre_kill_generation=$PreKillGeneration;post_kill_generation=$PostKillGeneration;kill_exit_code=$KillRun.exit_code;child_terminated=$KillRun.has_exited;recover_command="$Binary recover --root $Root";recover_exit_code=$RecoverRun.exit_code;recover_status=if($RecoverEnvelope){$RecoverEnvelope.state}else{'missing'};recovered_generation=$RecoveredGeneration;selector_valid=$SelectorValid;generation_exists=(Test-Path -LiteralPath $GenerationPath -PathType Container);manifest_valid=$ManifestValid;receipts_valid=($ReceiptResults.valid -notcontains $false);sqlite_valid=$SqliteValid;journal_valid=$JournalValid;journal_final_event=$JournalFinalEvent.event;journal_final_state=$JournalFinal.state;incomplete_generation_count=$Incomplete.Count;incomplete_generation_disposition=if($Incomplete.Count -eq 0){'none present; non-active staging preserved'}else{'invalid incomplete generation present'};mixed_generation_references=$MixedReferences;failures=$Failures} | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $Artifact 'summary.json')
  Write-DiagnosticRecord $Timeline ([ordered]@{schema_version=1;event='recovery_validation_complete';result=if($Passed){'PASS'}else{'FAIL'};generation=$RecoveredGeneration;failure_count=$Failures.Count})
  if (-not $Passed) { throw "CMN-008 recovery validation failed: $($Failures[0].category): $($Failures[0].detail)" }
}

function Invoke-ActivationPrimitiveProbes {
  param([string]$Root, [string]$Path)
  $ProbeRoot = Join-Path $Root 'activation-primitive-probes'
  New-Item -ItemType Directory -Force $ProbeRoot | Out-Null
  $Results = [Collections.Generic.List[object]]::new()
  function Probe([string]$Name, [scriptblock]$Body) {
    $Started = [Diagnostics.Stopwatch]::StartNew(); $ErrorText = ''; $Code = $null; $Passed = $true
    try { & $Body } catch { $Passed = $false; $ErrorText = $_.Exception.Message; $Code = ($_.Exception.HResult -band 0xffff) }
    $Started.Stop()
    $Record = [ordered]@{schema_version=1;event='diag_primitive_probe_result';probe=$Name;pass=$Passed;win32_code=$Code;raw_os_error=$Code;error_text=$ErrorText;elapsed_ms=$Started.ElapsedMilliseconds;root=$ProbeRoot}
    Write-DiagnosticRecord $Path $Record
    $Results.Add([pscustomobject]$Record)
  }
  Probe 'temp_file_write_flush' { $p=Join-Path $ProbeRoot 'flush.tmp'; $f=[IO.File]::Create($p); try { $b=[Text.Encoding]::UTF8.GetBytes('x'); $f.Write($b,0,$b.Length); $f.Flush($true) } finally { $f.Dispose() } }
  Probe 'file_rename_new_target' { $s=Join-Path $ProbeRoot 'rename-new.src'; [IO.File]::WriteAllText($s,'x'); [IO.File]::Move($s,(Join-Path $ProbeRoot 'rename-new.dst')) }
  Probe 'file_replace_existing_target' { $s=Join-Path $ProbeRoot 'replace.src'; $t=Join-Path $ProbeRoot 'replace.dst'; [IO.File]::WriteAllText($s,'new'); [IO.File]::WriteAllText($t,'old'); [IO.File]::Replace($s,$t,$null) }
  Probe 'source_handle_open_rename' { $s=Join-Path $ProbeRoot 'source-open.src'; [IO.File]::WriteAllText($s,'x'); $h=[IO.File]::OpenRead($s); try { [IO.File]::Move($s,(Join-Path $ProbeRoot 'source-open.dst')) } finally { $h.Dispose() } }
  Probe 'target_handle_open_replace' { $s=Join-Path $ProbeRoot 'target-open.src'; $t=Join-Path $ProbeRoot 'target-open.dst'; [IO.File]::WriteAllText($s,'new'); [IO.File]::WriteAllText($t,'old'); $h=[IO.File]::OpenRead($t); try { [IO.File]::Replace($s,$t,$null) } finally { $h.Dispose() } }
  Probe 'directory_rename' { $s=Join-Path $ProbeRoot 'dir.src'; New-Item -ItemType Directory $s | Out-Null; [IO.Directory]::Move($s,(Join-Path $ProbeRoot 'dir.dst')) }
  Probe 'directory_open_sync' { $env:POA_ACTIVATION_DIAGNOSTIC='1'; try { $r=Invoke-CapturedExternal $Binary @('diagnose-directory-open','--root',$ProbeRoot) (Join-Path $ProbeRoot 'dir-sync.stdout') (Join-Path $ProbeRoot 'dir-sync.stderr'); if ($r.exit_code -ne 0) { throw [IO.IOException]::new($r.stderr) } } finally { Remove-Item Env:POA_ACTIVATION_DIAGNOSTIC -ErrorAction SilentlyContinue } }
  Probe 'parent_directory_open_sync' { $parent=Split-Path -Parent $ProbeRoot; $env:POA_ACTIVATION_DIAGNOSTIC='1'; try { $r=Invoke-CapturedExternal $Binary @('diagnose-directory-open','--root',$parent) (Join-Path $ProbeRoot 'parent-sync.stdout') (Join-Path $ProbeRoot 'parent-sync.stderr'); if ($r.exit_code -ne 0) { throw [IO.IOException]::new($r.stderr) } } finally { Remove-Item Env:POA_ACTIVATION_DIAGNOSTIC -ErrorAction SilentlyContinue } }
  Probe 'remove_directory_open_child' { $d=Join-Path $ProbeRoot 'remove-open'; New-Item -ItemType Directory $d | Out-Null; $p=Join-Path $d 'child'; [IO.File]::WriteAllText($p,'x'); $h=[IO.File]::OpenRead($p); try { [IO.Directory]::Delete($d,$true) } finally { $h.Dispose() } }
  Probe 'selector_temp_write_replace' { $s=Join-Path $ProbeRoot 'active.tmp'; $t=Join-Path $ProbeRoot 'active'; [IO.File]::WriteAllText($s,'new'); [IO.File]::WriteAllText($t,'old'); [IO.File]::Replace($s,$t,$null) }
  Probe 'readonly_target' { $s=Join-Path $ProbeRoot 'readonly.src'; $t=Join-Path $ProbeRoot 'readonly.dst'; [IO.File]::WriteAllText($s,'new'); [IO.File]::WriteAllText($t,'old'); [IO.File]::SetAttributes($t,[IO.FileAttributes]::ReadOnly); try { [IO.File]::Replace($s,$t,$null) } finally { if (Test-Path $t) { [IO.File]::SetAttributes($t,[IO.FileAttributes]::Normal) } } }
  Probe 'deny_share_target' { $s=Join-Path $ProbeRoot 'deny.src'; $t=Join-Path $ProbeRoot 'deny.dst'; [IO.File]::WriteAllText($s,'new'); [IO.File]::WriteAllText($t,'old'); $h=[IO.File]::Open($t,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); try { [IO.File]::Replace($s,$t,$null) } finally { $h.Dispose() } }
  return @($Results)
}

function Run-CaseDiagnostic {
  param([string]$CaseId)
  $Artifact = Join-Path $Base "reports/results/windows-selector-durability-$CaseId"
  $CaseRoot = Join-Path $Base ("poa-roots/diagnostic-{0}-{1}" -f $CaseId, [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force $Artifact, $CaseRoot | Out-Null
  $Commands = Join-Path $Artifact 'commands.jsonl'
  $ProbeDir = Join-Path $Artifact 'probes'
  New-Item -ItemType Directory -Force $ProbeDir | Out-Null
  $PrimitiveResults = Invoke-ActivationPrimitiveProbes $CaseRoot (Join-Path $Artifact 'primitive-probes.jsonl')

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
  $env:POA_ACTIVATION_DIAGNOSTIC = '1'
  if ($CaseId -eq 'CMN-008') {
    $RecoveryArtifact = Join-Path $Base 'reports/results/windows-rust-CMN-008-recovery-validation'
    New-Item -ItemType Directory -Force $RecoveryArtifact | Out-Null
    $PreOut = Join-Path $Artifact 'prerequisite.stdout.log'
    $PreErr = Join-Path $Artifact 'prerequisite.stderr.log'
    Write-DiagnosticRecord $Commands ([ordered]@{event='diag_failure_context';phase='prerequisite_begin';case_id=$CaseId;binary=$Binary;arguments=$Arguments;root=$CaseRoot;catalog=$Catalog})
    $Run = Invoke-CapturedExternal $Binary $Arguments $PreOut $PreErr
    if ($Run.exit_code -eq 0) {
      $PreKillSelector = Get-Content -Raw -LiteralPath (Join-Path $CaseRoot 'state/active') | ConvertFrom-Json -ErrorAction Stop
      $PreKillGeneration = [string]$PreKillSelector.generation_id
      Save-RecoveryState $CaseRoot (Join-Path $RecoveryArtifact 'pre-kill')
      Write-DiagnosticRecord (Join-Path $RecoveryArtifact 'timeline.jsonl') ([ordered]@{schema_version=1;event='pre_kill_state_captured';root=$CaseRoot;generation=$PreKillGeneration})
      $env:POA_FAULT = 'kill_after_active_swap'
      try { $Run = Invoke-CapturedExternal $Binary $Arguments $Stdout $Stderr } finally { Remove-Item Env:POA_FAULT -ErrorAction SilentlyContinue }
      Invoke-CMN008RecoveryValidation $CaseRoot $RecoveryArtifact $Run $PreKillGeneration
    } else {
      Copy-Item -LiteralPath $PreOut -Destination $Stdout
      Copy-Item -LiteralPath $PreErr -Destination $Stderr
      throw "CMN-008 prerequisite failed: exit=$($Run.exit_code); stderr=$($Run.stderr)"
    }
  } else {
    $Run = Invoke-CapturedExternal $Binary $Arguments $Stdout $Stderr
  }
  Remove-Item Env:POA_ACTIVATION_DIAGNOSTIC -ErrorAction SilentlyContinue
  Copy-Item -LiteralPath $Stdout -Destination (Join-Path $Artifact 'jsonl.log')
  Copy-Item -LiteralPath $Stdout -Destination (Join-Path $Artifact 'events.jsonl')
  Get-Content -LiteralPath $Stdout | Where-Object { $_ -match '"event":"diag_' } | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $Artifact 'activation-timeline.jsonl')
  Get-Content -LiteralPath $Stdout | Where-Object { $_ -match 'diag_handle_' } | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $Artifact 'handles.tsv')
  Get-Content -LiteralPath $Stdout | Where-Object { $_ -match 'diag_failure_context|"status":"error"' } | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $Artifact 'errors.tsv')

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
  "relative_path`tattributes`treadonly" | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $Artifact 'attributes.tsv')
  Get-ChildItem -Force -Recurse -LiteralPath $CaseRoot | ForEach-Object { "$([IO.Path]::GetRelativePath($CaseRoot,$_.FullName))`t$($_.Attributes)`t$($_.IsReadOnly)" | Add-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $Artifact 'attributes.tsv') }
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
    activation_primitive_probes="$(@($PrimitiveResults).Count)/12"
  } | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $Artifact 'summary.json')
  if (Test-Path (Join-Path $CaseRoot 'state/journal')) { Copy-Item -Recurse -Force -LiteralPath (Join-Path $CaseRoot 'state/journal') -Destination (Join-Path $Artifact 'journal') }
  if (Test-Path (Join-Path $CaseRoot 'state')) { Copy-Item -Recurse -Force -LiteralPath (Join-Path $CaseRoot 'state') -Destination (Join-Path $Artifact 'state') }
  foreach ($ProbeEvidence in @('api-probes.jsonl','win32-errors.tsv','flags.tsv','selector-hashes.tsv','process-crash-probes.tsv')) {
    Copy-Item -Force -LiteralPath (Join-Path $ProbeArtifact $ProbeEvidence) -Destination (Join-Path $Artifact $ProbeEvidence)
  }
  Copy-Item -Recurse -Force -LiteralPath $CaseRoot -Destination (Join-Path $Artifact 'case-root')
}

Set-Location $Base
$ProbeArtifact = Join-Path $Base 'reports/results/windows-selector-durability-probes'
$ProbeRoot = Join-Path $Base ("poa-roots/durability-probes-{0}" -f [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $ProbeArtifact, $ProbeRoot | Out-Null
$ProbeStdout = Join-Path $ProbeArtifact 'api-probes.jsonl'
$ProbeStderr = Join-Path $ProbeArtifact 'stderr.log'
$env:POA_ACTIVATION_DIAGNOSTIC = '1'
try {
  $ProbeRun = Invoke-CapturedExternal $Binary @('diagnose-selector-durability','--root',$ProbeRoot) $ProbeStdout $ProbeStderr
} finally {
  Remove-Item Env:POA_ACTIVATION_DIAGNOSTIC -ErrorAction SilentlyContinue
}
if ($ProbeRun.exit_code -ne 0) { throw "Windows selector durability probes failed: $($ProbeRun.stderr)" }
$ProbeRecords = @(Get-Content -LiteralPath $ProbeStdout | ForEach-Object { $_ | ConvertFrom-Json })
if ($ProbeRecords.Count -ne 18) { throw "Expected 18 durability probes, got $($ProbeRecords.Count)" }
Copy-Item -LiteralPath $ProbeStdout -Destination (Join-Path $ProbeArtifact 'activation-timeline.jsonl')
$ProbeRecords | Where-Object { $_.win32_code -ne 0 } | ForEach-Object { "$($_.candidate_id)`t$($_.api)`t$($_.win32_code)" } | Set-Content -Encoding utf8NoBOM (Join-Path $ProbeArtifact 'win32-errors.tsv')
$ProbeRecords | ForEach-Object { "$($_.candidate_id)`t$($_.api)`t$($_.flags)`t$($_.handle_access)`t$($_.handle_share)" } | Set-Content -Encoding utf8NoBOM (Join-Path $ProbeArtifact 'flags.tsv')
Get-ChildItem -File -Recurse -LiteralPath $ProbeRoot | ForEach-Object { "$([IO.Path]::GetRelativePath($ProbeRoot,$_.FullName))`t$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant())" } | Set-Content -Encoding utf8NoBOM (Join-Path $ProbeArtifact 'selector-hashes.tsv')
$ProbeRecords | Where-Object { $_.candidate_id -ge 16 } | ConvertTo-Csv -Delimiter "`t" -NoTypeInformation | Set-Content -Encoding utf8NoBOM (Join-Path $ProbeArtifact 'process-crash-probes.tsv')
Copy-Item -LiteralPath $ProbeStdout -Destination (Join-Path $ProbeArtifact 'stdout.log')
Copy-Item -LiteralPath $ProbeStdout -Destination (Join-Path $ProbeArtifact 'events.jsonl')
Write-TreeEvidence $ProbeRoot (Join-Path $ProbeArtifact 'tree.tsv') (Join-Path $ProbeArtifact 'selector-hashes-full.tsv')
[ordered]@{schema_version=1;probe_count=$ProbeRecords.Count;process_exit_code=$ProbeRun.exit_code;power_loss_claim=$false} | ConvertTo-Json | Set-Content -Encoding utf8NoBOM (Join-Path $ProbeArtifact 'summary.json')
Copy-Item -Recurse -Force -LiteralPath $ProbeRoot -Destination (Join-Path $ProbeArtifact 'case-root')
foreach ($CaseId in $Cases.Split(',')) { Run-CaseDiagnostic $CaseId }
