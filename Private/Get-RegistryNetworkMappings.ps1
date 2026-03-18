# Get-RegistryNetworkMappings.ps1
#
# Reads HKCU\Network from a user's ntuser.dat to find persistently mapped drives
# that were created via the "Reconnect at sign-in" checkbox in Windows Explorer
# or via net use /persistent:yes.
#
# Important limitations:
#   - The user must be LOGGED OFF — ntuser.dat is locked while they are signed in.
#   - Requires local admin rights (reg load uses SeRestorePrivilege).
#   - If either condition isn't met, the hive load fails silently and an empty
#     list is returned (the script logs a WARN but continues).
#
# Returns a list of objects with: Drive, Path, UserName, Provider, Method
#
# Parameters:
#   ProfilePath — UNC path to the user's profile root (from AD profilePath attribute)
#   SamAccount  — Username, used only for the temporary hive key name and log messages

function Get-RegistryNetworkMappings {
    param(
        [string] $ProfilePath,
        [string] $SamAccount
    )

    $out    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $hive   = Join-Path $ProfilePath 'NTUSER.DAT'
    $mount  = "HKU\TempAudit_${SamAccount}_$(Get-Random -Maximum 99999)"
    $loaded = $false

    # Bail early if the profile path is missing or the DAT file isn't there.
    if ([string]::IsNullOrWhiteSpace($ProfilePath) -or
        -not (Test-Path -LiteralPath $hive -EA SilentlyContinue)) {
        return $out
    }

    try {
        # Load the hive under a temporary key in HKU.
        # This will fail if the user is logged in (file locked) or if the caller
        # doesn't have local admin / SeRestorePrivilege.
        $result = & reg load $mount "`"$hive`"" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Log "Hive load failed for $SamAccount (user may be logged in, or insufficient rights): $result" 'WARN'
            return $out
        }
        $loaded = $true

        # Read each subkey under HKCU\Network — each one is a mapped drive letter.
        $netKey = "Registry::$mount\Network"
        if (Test-Path $netKey -EA SilentlyContinue) {
            Get-ChildItem $netKey -EA SilentlyContinue | ForEach-Object {
                try {
                    $props = Get-ItemProperty -LiteralPath $_.PSPath -EA Stop
                    $out.Add([PSCustomObject]@{
                        Drive    = "$($_.PSChildName.ToUpper()):"
                        Path     = $props.RemotePath
                        UserName = if ($props.PSObject.Properties['UserName'])     { $props.UserName     } else { '' }
                        Provider = if ($props.PSObject.Properties['ProviderName']) { $props.ProviderName } else { '' }
                        Method   = 'HKCU\Network (ntuser.dat)'
                    })
                } catch { }
            }
        }
    } catch {
        Log "Registry hive error for ${SamAccount}: $_" 'WARN'
    } finally {
        if ($loaded) {
            # Force garbage collection before unloading — PowerShell may still hold
            # handles to registry objects, which would cause reg.exe to report the
            # key is in use and refuse to unload it.
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            Start-Sleep -Milliseconds 300
            & reg unload $mount 2>&1 | Out-Null
        }
    }

    return $out
}
