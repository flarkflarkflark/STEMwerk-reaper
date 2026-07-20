param([Parameter(Mandatory=$true)][string]$ExpectedArch)
$ErrorActionPreference = 'Stop'
$Arch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
if ($ExpectedArch -eq 'x86_64' -and $Arch -notin @('x64','x86_64')) { throw "FAIL_NATIVE_ARCH_ASSERT expected x86_64, got $Arch" }
$Drive = (Get-Item $PWD.Path).PSDrive
$Filesystem = (Get-Volume -DriveLetter $Drive.Name).FileSystem
if ($Filesystem -ne 'NTFS') { throw "Expected NTFS, got $Filesystem" }
Write-Output "NATIVE_OS=Windows"
Write-Output "NATIVE_ARCH=$Arch"
Write-Output "FILESYSTEM=$Filesystem"
