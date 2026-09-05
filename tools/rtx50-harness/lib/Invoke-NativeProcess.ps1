# Invoke-NativeProcess.ps1
#
# Root cause this file fixes (STEMwerk #118 harness failure #2):
#
#   Windows PowerShell 5.1 converts a native process's stderr text into
#   PowerShell ErrorRecord objects whenever it is observed through the
#   success/error pipeline (e.g. `$out = & $exe $args 2>&1`). If
#   $ErrorActionPreference is 'Stop' (or becomes Stop anywhere up the call
#   stack), the *first* stderr line thrown into the pipeline as an
#   ErrorRecord is treated as a terminating error: "NativeCommandError".
#   This happens even when the process's real exit code is 0 and the
#   stderr text is a completely harmless Python UserWarning
#   (e.g. from torch\cuda\__init__.py).
#
#   This helper never routes the child process's stdout/stderr through
#   PowerShell's success/error streams at all. It talks to
#   System.Diagnostics.Process directly, reads stdout and stderr via the
#   asynchronous OutputDataReceived/ErrorDataReceived events (avoiding the
#   classic redirected-pipe deadlock), and reports the process's *real*
#   exit code separately from whatever text it wrote to stderr. Only a
#   genuine PowerShell-level exception (e.g. the executable does not
#   exist) is treated as a harness-level error.
#
# PowerShell 5.1 compatibility notes:
#   - Windows PowerShell 5.1 runs on .NET Framework, so
#     System.Diagnostics.ProcessStartInfo has no ArgumentList collection
#     (that is a .NET Core / PowerShell 7 addition). Arguments must be
#     joined into a single pre-escaped string via the .Arguments property.
#   - No use of $IsWindows, ternary (?:), null-coalescing (??), or other
#     PowerShell 7-only syntax anywhere in this file.

Set-StrictMode -Version Latest

function Format-NativeArgument {
    <#
        .SYNOPSIS
        Escapes a single argument per the Windows CommandLineToArgvW
        convention so it survives Process.Start with -Arguments as a
        plain string (handles spaces, quotes, and trailing backslashes).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.Length -eq 0) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
            continue
        }
        if ($ch -eq '"') {
            [void]$sb.Append('\', ($backslashes * 2 + 1))
            [void]$sb.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$sb.Append('\', $backslashes)
            $backslashes = 0
        }
        [void]$sb.Append($ch)
    }
    if ($backslashes -gt 0) {
        [void]$sb.Append('\', ($backslashes * 2))
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-NativeProcess {
    <#
        .SYNOPSIS
        Runs a native executable without letting Windows PowerShell 5.1
        reinterpret its stderr output as a terminating PowerShell error.

        .OUTPUTS
        PSCustomObject with:
          ExitCode          - the real process exit code ($null only if the
                               process could never be started)
          StdOut            - full captured standard output (string)
          StdErr            - full captured standard error (string)
          Success           - $true when ExitCode -eq 0 and no PowerShell-
                               level launch exception occurred
          LaunchException   - $null, or the PowerShell-level exception that
                               prevented the process from running at all
                               (executable missing, access denied, etc.)
          TimedOut          - $true if -TimeoutSeconds elapsed first
          DurationMs        - wall-clock duration in milliseconds
          CommandLine       - the fully escaped command line that was run
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$ArgumentList = @(),

        [string]$WorkingDirectory = $null,

        [int]$TimeoutSeconds = 0
    )

    $result = [PSCustomObject]@{
        ExitCode        = $null
        StdOut          = ''
        StdErr          = ''
        Success         = $false
        LaunchException = $null
        TimedOut        = $false
        DurationMs      = 0
        CommandLine     = ''
    }

    $escapedArgs = @()
    foreach ($a in $ArgumentList) {
        $escapedArgs += Format-NativeArgument -Value $a
    }
    $argString = [string]::Join(' ', $escapedArgs)
    $result.CommandLine = "$FilePath $argString".Trim()

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $argString
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) {
        $psi.WorkingDirectory = $WorkingDirectory
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stdoutText = ''
    $stderrText = ''

    try {
        # NOTE: an earlier version of this function used
        # Register-ObjectEvent + OutputDataReceived/ErrorDataReceived to
        # capture output line-by-line into a shared StringBuilder. That
        # approach was found (via the #118 harness's own regression
        # testing) to occasionally interleave/reorder lines - the
        # PowerShell event queue does not guarantee the same delivery
        # order the child process wrote them in when many lines arrive in
        # a burst. This corrupted captured JSON output.
        #
        # ReadToEndAsync avoids that entirely: each stream is read by a
        # single sequential async read with no PowerShell eventing
        # involved, so line order can never be scrambled. Starting both
        # reads before WaitForExit() (rather than after) is what avoids
        # the classic redirected-pipe deadlock (child blocks writing to a
        # full pipe buffer while the parent blocks waiting for exit).
        [void]$proc.Start()
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        if ($TimeoutSeconds -gt 0) {
            $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
            if (-not $exited) {
                $result.TimedOut = $true
                try { $proc.Kill() } catch { }
                $proc.WaitForExit(5000) | Out-Null
            }
        }
        else {
            $proc.WaitForExit()
        }

        # The streams close at (or immediately after) process exit, so
        # these complete right away; a bounded wait keeps a killed/
        # misbehaving process from hanging the harness forever.
        if ([System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 15000)) {
            $stdoutText = $stdoutTask.GetAwaiter().GetResult()
            $stderrText = $stderrTask.GetAwaiter().GetResult()
        }

        if (-not $result.TimedOut) {
            $result.ExitCode = $proc.ExitCode
        }
    }
    catch {
        # A genuine PowerShell-level failure to launch the process
        # (executable not found, access denied, etc.) - NOT the same
        # thing as the child process writing to stderr or exiting
        # non-zero. This is the only case treated as a harness-level
        # exception by this function.
        $result.LaunchException = $_
    }
    finally {
        $proc.Dispose()
    }

    $sw.Stop()
    $result.DurationMs = $sw.ElapsedMilliseconds
    $result.StdOut = $stdoutText
    $result.StdErr = $stderrText

    if ($null -eq $result.LaunchException -and -not $result.TimedOut -and $result.ExitCode -eq 0) {
        $result.Success = $true
    }

    return $result
}
