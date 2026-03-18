# Get-LogonScriptMappings.ps1
#
# Reads a user's logon script and extracts any drive mapping commands from it.
# Supports three mapping styles:
#   - net use X: \\server\share        (CMD / BAT, or called from within a PS1)
#   - .MapNetworkDrive("X:", "\\...")  (VBScript)
#   - New-PSDrive -Name X -Root \\...  (PowerShell)
#
# Returns a list of objects with: Drive, Path, Method, ScriptFile
#
# Parameters:
#   ScriptRelPath — The scriptPath value from AD (filename or relative path)
#   NetlogonBase  — Optional override for the NETLOGON share root UNC path

function Get-LogonScriptMappings {
    param(
        [string] $ScriptRelPath,
        [string] $NetlogonBase
    )

    $out = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ([string]::IsNullOrWhiteSpace($ScriptRelPath)) { return $out }

    # Build a list of places to look for the script file.
    # Priority: absolute path > explicit NETLOGON override > auto-detected domain NETLOGON.
    $candidates = @()

    if ([IO.Path]::IsPathRooted($ScriptRelPath)) {
        $candidates += $ScriptRelPath
    }

    if ($NetlogonBase) {
        $candidates += Join-Path $NetlogonBase $ScriptRelPath
    }

    try {
        $dom = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        $candidates += "\\$($dom.Name)\NETLOGON\$ScriptRelPath"
    } catch { }

    # Try each candidate path until we find one we can read.
    $content  = $null
    $resolved = $ScriptRelPath  # used in output so we always know where it came from

    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -EA SilentlyContinue) {
            try {
                $content  = Get-Content -LiteralPath $c -Raw -EA Stop
                $resolved = $c
                break
            } catch { }
        }
    }

    # Script path is set in AD but the file can't be read (missing, locked, no access).
    if ($null -eq $content) {
        $out.Add([PSCustomObject]@{
            Drive      = ''
            Path       = ''
            Method     = 'Script not accessible'
            ScriptFile = $ScriptRelPath
        })
        return $out
    }

    $ext = [IO.Path]::GetExtension($resolved).ToLower()

    # Pattern 1 — net use X: \\server\share
    # Appears in CMD/BAT files and is sometimes also called from PS1 scripts.
    $netUseMethod = if ($ext -in '.ps1', '.psm1') { 'net use (inside PS1)' } else { 'net use (CMD/BAT)' }
    [regex]'(?im)^\s*net\s+use\s+([A-Za-z]:)\s+"?(\\\\[^"\s\r\n]+)"?'.Matches($content) | ForEach-Object {
        $out.Add([PSCustomObject]@{
            Drive      = $_.Groups[1].Value.ToUpper()
            Path       = $_.Groups[2].Value.TrimEnd('\')
            Method     = $netUseMethod
            ScriptFile = $resolved
        })
    }

    # Pattern 2 — objNet.MapNetworkDrive("X:", "\\server\share")  (VBScript)
    [regex]'(?i)\.MapNetworkDrive\s*\(\s*"([A-Za-z]:)"\s*,\s*"(\\\\[^"]+)"'.Matches($content) | ForEach-Object {
        $out.Add([PSCustomObject]@{
            Drive      = $_.Groups[1].Value.ToUpper()
            Path       = $_.Groups[2].Value.TrimEnd('\')
            Method     = 'MapNetworkDrive (VBScript)'
            ScriptFile = $resolved
        })
    }

    # Pattern 3 — New-PSDrive -Name X -Root \\server\share -Persist  (PowerShell)
    [regex]'(?is)New-PSDrive[^|&\r\n]*?-Name\s+[''"]?([A-Za-z])[''"]?[^|&\r\n]*?-Root\s+[''"]?(\\\\[^''"\s\r\n]+)'.Matches($content) | ForEach-Object {
        $out.Add([PSCustomObject]@{
            Drive      = "$($_.Groups[1].Value.ToUpper()):"
            Path       = $_.Groups[2].Value.TrimEnd('\')
            Method     = 'New-PSDrive (PowerShell)'
            ScriptFile = $resolved
        })
    }

    return $out
}
