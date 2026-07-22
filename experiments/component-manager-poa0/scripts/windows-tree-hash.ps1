$ErrorActionPreference = 'Stop'

function ConvertTo-CanonicalRelativePath([string]$Path) {
  if ([string]::IsNullOrEmpty($Path)) { throw 'Empty relative path is not canonical' }
  $Path.Replace('\', '/')
}

function Sort-CanonicalRelativePaths([string[]]$Paths) {
  $Normalized = [Collections.Generic.List[string]]::new()
  $Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($Path in $Paths) {
    $Canonical = ConvertTo-CanonicalRelativePath $Path
    if (-not $Seen.Add($Canonical)) { throw "Duplicate normalized path: $Canonical" }
    $Normalized.Add($Canonical)
  }
  $Result = $Normalized.ToArray()
  [Array]::Sort($Result, [StringComparer]::Ordinal)
  $Result
}

function Get-FrozenTreeRecordSet([string]$Directory) {
  $Root = (Resolve-Path -LiteralPath $Directory).Path
  $ByPath = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
  foreach ($File in Get-ChildItem -LiteralPath $Root -File -Recurse | Where-Object Name -ne 'Cargo.lock') {
    $Relative = ConvertTo-CanonicalRelativePath ([IO.Path]::GetRelativePath($Root, $File.FullName))
    if (-not $ByPath.TryAdd($Relative, $File.FullName)) { throw "Duplicate normalized path: $Relative" }
  }
  $Paths = @(Sort-CanonicalRelativePaths ([string[]]$ByPath.Keys))
  $Records = @($Paths | ForEach-Object {
    $Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ByPath[$_]).Hash.ToLowerInvariant()
    "$Hash  $_"
  })
  $Text = ($Records -join "`n") + "`n"
  $Bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
  $HashBytes = [Security.Cryptography.SHA256]::HashData($Bytes)
  [pscustomobject]@{
    Hash = -join ($HashBytes | ForEach-Object { $_.ToString('x2') })
    Paths = $Paths
    Records = $Records
    RecordBytes = $Bytes
  }
}

function Assert-FrozenTreeHash([string]$Directory, [string]$ExpectedHash) {
  $Actual = (Get-FrozenTreeRecordSet $Directory).Hash
  if ($Actual -cne $ExpectedHash) { throw "Frozen tree drift: expected $ExpectedHash, actual $Actual" }
}
