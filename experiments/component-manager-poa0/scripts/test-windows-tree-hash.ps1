param()
$ErrorActionPreference = 'Stop'
$Base = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. "$Base/scripts/windows-tree-hash.ps1"

$Passed = 0
$Failed = 0
function Run-Test([string]$Name, [scriptblock]$Test) {
  try {
    & $Test
    $script:Passed++
    Write-Output "$Name=PASS"
  } catch {
    $script:Failed++
    Write-Error "$Name=FAIL $($_.Exception.Message)"
  }
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -cne $Expected) { throw "$Message expected=$Expected actual=$Actual" }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
  try { & $Action } catch { return }
  throw "$Message did not fail closed"
}
function New-Fixture([string]$Root) {
  New-Item -ItemType Directory -Force (Join-Path $Root 'nested') | Out-Null
  [IO.File]::WriteAllBytes((Join-Path $Root 'Alpha.go'), [Text.Encoding]::UTF8.GetBytes('alpha'))
  [IO.File]::WriteAllBytes((Join-Path $Root 'alpha.go'), [Text.Encoding]::UTF8.GetBytes('lower'))
  [IO.File]::WriteAllBytes((Join-Path $Root 'a_test.go'), [Text.Encoding]::UTF8.GetBytes('underscore'))
  [IO.File]::WriteAllBytes((Join-Path $Root 'a-file.go'), [Text.Encoding]::UTF8.GetBytes('hyphen'))
  [IO.File]::WriteAllBytes((Join-Path $Root 'a1.go'), [Text.Encoding]::UTF8.GetBytes('digit'))
  [IO.File]::WriteAllBytes((Join-Path $Root 'nested/z.go'), [Text.Encoding]::UTF8.GetBytes('nested'))
}

$Manifest = Get-Content -Raw (Join-Path $Base 'FROZEN_FIXTURE_MANIFEST.json') | ConvertFrom-Json
$ManifestShaBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Base 'FROZEN_FIXTURE_MANIFEST.json')).Hash.ToLowerInvariant()
$OriginalCulture = [Globalization.CultureInfo]::CurrentCulture
$Temp = Join-Path ([IO.Path]::GetTempPath()) ("poa0-tree-hash-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force $Temp | Out-Null
try {
  $Fixture = Join-Path $Temp 'fixture'
  New-Fixture $Fixture
  $FixtureHash = (Get-FrozenTreeRecordSet $Fixture).Hash

  Run-Test 'REFERENCE_HASH_MATCH_TEST' {
    Assert-Equal (Get-FrozenTreeRecordSet (Join-Path $Base 'go')).Hash $Manifest.go_source_tree_hash 'Go reference hash'
  }
  Run-Test 'REVERSED_INPUT_ORDER_TEST' {
    $Paths = @('z.go','a.go','m.go')
    $Reversed = $Paths.Clone()
    [array]::Reverse($Reversed)
    Assert-Equal ((Sort-CanonicalRelativePaths $Paths) -join ',') ((Sort-CanonicalRelativePaths $Reversed) -join ',') 'Reversed input order'
  }
  Run-Test 'CASE_SENSITIVE_ORDER_TEST' {
    Assert-Equal ((Sort-CanonicalRelativePaths @('alpha.go','Alpha.go')) -join ',') 'Alpha.go,alpha.go' 'Case-sensitive order'
  }
  Run-Test 'UNDERSCORE_ORDER_TEST' {
    Assert-Equal ((Sort-CanonicalRelativePaths @('a_test.go','a.go')) -join ',') 'a.go,a_test.go' 'Underscore order'
  }
  Run-Test 'HYPHEN_ORDER_TEST' {
    Assert-Equal ((Sort-CanonicalRelativePaths @('a.go','a-file.go')) -join ',') 'a-file.go,a.go' 'Hyphen order'
  }
  Run-Test 'DIGIT_ORDER_TEST' {
    Assert-Equal ((Sort-CanonicalRelativePaths @('a.go','a1.go')) -join ',') 'a.go,a1.go' 'Digit order'
  }
  Run-Test 'NESTED_PATH_TEST' {
    Assert-Equal ((Sort-CanonicalRelativePaths @('nested/z.go','nested/a.go')) -join ',') 'nested/a.go,nested/z.go' 'Nested order'
  }
  Run-Test 'SEPARATOR_NORMALIZATION_TEST' {
    Assert-Equal ((Sort-CanonicalRelativePaths @('nested\z.go','nested/a.go')) -join ',') 'nested/a.go,nested/z.go' 'Separator normalization'
  }
  foreach ($CultureName in @('en-US','nl-NL','tr-TR')) {
    Run-Test ("{0}_CULTURE_TEST" -f $CultureName.Replace('-','_').ToUpperInvariant()) {
      [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($CultureName)
      Assert-Equal (Get-FrozenTreeRecordSet $Fixture).Hash $FixtureHash "$CultureName culture independence"
    }
  }
  Run-Test 'MISSING_FILE_REJECTED' {
    Remove-Item -LiteralPath (Join-Path $Fixture 'a1.go')
    Assert-Throws { Assert-FrozenTreeHash $Fixture $FixtureHash } 'Missing file'
    [IO.File]::WriteAllBytes((Join-Path $Fixture 'a1.go'), [Text.Encoding]::UTF8.GetBytes('digit'))
  }
  Run-Test 'EXTRA_FILE_REJECTED' {
    [IO.File]::WriteAllBytes((Join-Path $Fixture 'extra.go'), [Text.Encoding]::UTF8.GetBytes('extra'))
    Assert-Throws { Assert-FrozenTreeHash $Fixture $FixtureHash } 'Extra file'
    Remove-Item -LiteralPath (Join-Path $Fixture 'extra.go')
  }
  Run-Test 'BYTE_DRIFT_REJECTED' {
    [IO.File]::WriteAllBytes((Join-Path $Fixture 'alpha.go'), [Text.Encoding]::UTF8.GetBytes('changed'))
    Assert-Throws { Assert-FrozenTreeHash $Fixture $FixtureHash } 'Byte drift'
    [IO.File]::WriteAllBytes((Join-Path $Fixture 'alpha.go'), [Text.Encoding]::UTF8.GetBytes('lower'))
  }
  Run-Test 'PATH_DRIFT_REJECTED' {
    Rename-Item -LiteralPath (Join-Path $Fixture 'a1.go') -NewName 'a2.go'
    Assert-Throws { Assert-FrozenTreeHash $Fixture $FixtureHash } 'Path drift'
    Rename-Item -LiteralPath (Join-Path $Fixture 'a2.go') -NewName 'a1.go'
  }
  Run-Test 'DUPLICATE_NORMALIZED_PATH_REJECTED' {
    Assert-Throws { Sort-CanonicalRelativePaths @('nested/a.go','nested\a.go') } 'Duplicate normalized path'
  }
  Run-Test 'LF_RECORD_TEST' {
    $Set = Get-FrozenTreeRecordSet $Fixture
    if ($Set.RecordBytes -contains 13) { throw 'CR byte found in canonical records' }
    Assert-Equal $Set.RecordBytes[-1] 10 'Final LF'
  }
  Run-Test 'MANIFEST_HASH_UNCHANGED_TEST' {
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Base 'FROZEN_FIXTURE_MANIFEST.json')).Hash.ToLowerInvariant() $ManifestShaBefore 'Manifest SHA'
  }
  Run-Test 'RUST_TREE_UNCHANGED_TEST' {
    Assert-FrozenTreeHash (Join-Path $Base 'rust') $Manifest.rust_source_tree_hash
  }
  Run-Test 'HARNESS_TREE_UNCHANGED_TEST' {
    Assert-FrozenTreeHash (Join-Path $Base 'harness') $Manifest.harness_tree_hash
  }
} finally {
  [Globalization.CultureInfo]::CurrentCulture = $OriginalCulture
  Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "WINDOWS_TREE_HASH_TESTS=$Passed/20"
if ($Failed -ne 0 -or $Passed -ne 20) { throw "Windows tree-hash regressions failed: passed=$Passed failed=$Failed" }
