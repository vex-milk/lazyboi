#Requires -Version 5.1
# Audit-UserHomeDriveMappings.ps1
#
# Audits home drive mappings for AD users from four sources:
#   1. AD attributes     — homeDirectory / homeDrive / profilePath
#   2. Logon scripts     — net use, MapNetworkDrive (VBScript), New-PSDrive (PS)
#   3. GPO Drive Maps    — SYSVOL Policies\...\Drives.xml
#   4. Registry          — HKCU\Network from ntuser.dat (opt-in, user must be logged off)
#
# Also records per-user: folder existence, last-modified dates, file count, and ACL rights.
# Output: CSV always; add -ExcelOutput for .xlsx (requires: Install-Module ImportExcel)
#
# Required permissions (no Domain Admin needed):
#   - Domain Users group (gives read access to AD user objects, NETLOGON, and SYSVOL automatically)
#   - Read access to the home directory share(s)  e.g. \\fileserver\homes$
#   - Read access to the profile share (only if using -TryRegistryLoad)
#
# Examples:
#   .\Audit-UserHomeDriveMappings.ps1
#   .\Audit-UserHomeDriveMappings.ps1 -InputCsv users.csv -ExcelOutput
#   .\Audit-UserHomeDriveMappings.ps1 -SearchBase "OU=Staff,DC=corp,DC=local" -EnabledOnly -DeepScan

[CmdletBinding()]
param(
    [string]$OutputCsv    = ".\UserHomeDriveAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",
    [string]$InputCsv     = '',          # CSV with username list; omit to query all AD users
    [string]$SearchBase   = '',          # Limit to an OU, e.g. "OU=Staff,DC=corp,DC=local"
    [string]$NetlogonPath = '',          # Override auto-detected NETLOGON UNC path
    [string]$SysvolPath   = '',          # Override auto-detected SYSVOL UNC path
    [switch]$EnabledOnly,                # Skip disabled accounts
    [switch]$SkipFolderStats,            # Don't touch the file system (fast, identity-only)
    [switch]$SkipPermissionCheck,        # Skip ACL inspection
    [switch]$SkipGpoDriveMaps,           # Skip SYSVOL Drives.xml scan
    [switch]$SkipLogonScriptParse,       # Skip logon script parsing
    [switch]$DeepScan,                   # Recurse full directory tree (slow on large drives)
    [switch]$TryRegistryLoad,            # Load ntuser.dat for HKCU\Network (user must be logged off)
    [switch]$ExcelOutput                 # Also write .xlsx (requires ImportExcel module)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# Compact logging — Log "message" or Log "message" 'WARN' / 'ERROR'
function Log ($msg, $lvl = 'INFO') {
    $color = @{ INFO='Cyan'; WARN='Yellow'; ERROR='Red' }[$lvl]
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')][$lvl] $msg" -ForegroundColor $color
}

# Load helper functions from the Private subfolder.
# Each file contains one function with full comments explaining what it does.
. "$PSScriptRoot\Private\Get-FolderStats.ps1"             # Folder existence, timestamps, file count, ACL
. "$PSScriptRoot\Private\Get-LogonScriptMappings.ps1"     # Parse logon scripts for net use / MapNetworkDrive / New-PSDrive
. "$PSScriptRoot\Private\Get-GpoDriveMaps.ps1"            # Read Drives.xml from SYSVOL GPO Preferences
. "$PSScriptRoot\Private\Get-RegistryNetworkMappings.ps1" # Load HKCU\Network from ntuser.dat (requires local admin)

# ── Main ──────────────────────────────────────────────────────────────────────

Log "Home Drive Mapping Audit started"
Log "Output : $OutputCsv | Input: $(if ($InputCsv) { $InputCsv } else { 'full AD query' })"

# Load the ActiveDirectory module (part of RSAT — no elevated rights required)
if (-not (Get-Module ActiveDirectory -EA SilentlyContinue)) {
    try   { Import-Module ActiveDirectory -EA Stop }
    catch { Log "ActiveDirectory module not found. Install RSAT AD DS Tools." 'ERROR'; exit 1 }
}

$adProps = @(
    'SamAccountName', 'DisplayName', 'mail', 'Enabled',
    'homeDirectory',  'homeDrive',   'scriptPath', 'profilePath',
    'distinguishedName', 'SID',
    'lastLogonDate',  'PasswordLastSet', 'Description', 'Department'
)

# ── Build user list — from InputCsv or a full AD query ────────────────────────
$users = [System.Collections.Generic.List[object]]::new()

if (-not [string]::IsNullOrWhiteSpace($InputCsv)) {

    if (-not (Test-Path -LiteralPath $InputCsv -EA SilentlyContinue)) { Log "InputCsv not found: $InputCsv" 'ERROR'; exit 1 }
    $csvRows = @(Import-Csv -LiteralPath $InputCsv -EA Stop)
    if ($csvRows.Count -eq 0) { Log "InputCsv has no data rows." 'WARN'; exit 0 }

    # Detect username column — try known names, fall back to the first column
    $userCol = @('SamAccountName','Username','UserName','User','Name') |
               Where-Object { $csvRows[0].PSObject.Properties.Name -contains $_ } |
               Select-Object -First 1
    if (-not $userCol) {
        $userCol = $csvRows[0].PSObject.Properties.Name[0]
        Log "No recognised username column — using first column '$userCol'" 'WARN'
    }

    $notFound = 0
    foreach ($row in $csvRows) {
        $sam = ($row.$userCol).Trim()
        if ([string]::IsNullOrWhiteSpace($sam)) { continue }
        try {
            $u = Get-ADUser -Identity $sam -Properties $adProps -EA Stop
            if ($EnabledOnly -and -not $u.Enabled) { continue }
            $users.Add($u)
        } catch { $notFound++; Log "Not found in AD: '$sam'" 'WARN' }
    }
    Log "Resolved $($users.Count) user(s) from CSV ($notFound not found)."

} else {

    # Query the whole domain (or an OU if -SearchBase is set)
    $adArgs = @{ Filter = $(if ($EnabledOnly) { {Enabled -eq $true} } else { '*' }); Properties = $adProps; ErrorAction = 'Stop' }
    if ($SearchBase) { $adArgs['SearchBase'] = $SearchBase }
    try   { @(Get-ADUser @adArgs) | ForEach-Object { $users.Add($_) } }
    catch { Log "AD query failed: $_" 'ERROR'; exit 1 }
    Log "Found $($users.Count) AD user(s)."
}

# ── Scan SYSVOL once upfront — results are shared across all users ─────────────
$allGpoMaps = [System.Collections.Generic.List[PSCustomObject]]::new()
if (-not $SkipGpoDriveMaps) {
    Log "Scanning SYSVOL for GPO drive maps..."
    try { @(Get-GpoDriveMaps -SysvolBase $SysvolPath) | ForEach-Object { $allGpoMaps.Add($_) } }
    catch { Log "GPO scan error: $_" 'WARN' }
    Log "  $($allGpoMaps.Count) entries ($((($allGpoMaps | Where-Object HasFilters).Count)) with item-level targeting)"
}

# ── Process each user and collect all mapping data ────────────────────────────
$rows = [System.Collections.Generic.List[PSCustomObject]]::new()
$total = $users.Count; $i = 0; $errCount = 0

foreach ($u in $users) {
    if ((++$i) % 50 -eq 0 -or $i -eq $total) { Log "  $i / $total" }

    # Source 1 — AD attributes: homeDirectory (primary home drive) and profilePath (roaming profile)
    $adMaps = @()
    if ($u.homeDirectory) { $adMaps += [PSCustomObject]@{ Drive = $(if ($u.homeDrive) { $u.homeDrive } else { '(not set)' }); Path = $u.homeDirectory } }
    if ($u.profilePath)   { $adMaps += [PSCustomObject]@{ Drive = ''; Path = $u.profilePath } }

    # Source 2 — Logon script: parse the script file referenced in AD scriptPath
    $logonMaps = @()
    if (-not $SkipLogonScriptParse -and $u.scriptPath) {
        try   { $logonMaps = @(Get-LogonScriptMappings -ScriptRelPath $u.scriptPath -NetlogonBase $NetlogonPath) }
        catch { $errCount++; Log "Logon script error [$($u.SamAccountName)]: $_" 'WARN' }
    }

    # Source 3 — GPO: all Drives.xml entries are shown for every user.
    # [TARGETED] entries have item-level targeting and may not apply to this specific user.
    $gpoMaps = @($allGpoMaps)

    # Source 4 — Registry: HKCU\Network keys loaded from ntuser.dat (opt-in, user must be logged off)
    $regMaps = @()
    if ($TryRegistryLoad -and $u.profilePath) {
        try   { $regMaps = @(Get-RegistryNetworkMappings -ProfilePath $u.profilePath -SamAccount $u.SamAccountName) }
        catch { $errCount++; Log "Registry error [$($u.SamAccountName)]: $_" 'WARN' }
    }

    # Folder stats for the primary home directory (skipped if -SkipFolderStats or no homeDirectory)
    $emptyFs = [PSCustomObject]@{ Folder_Exists=''; Folder_LastModified=''; Folder_LatestFile=''; Folder_FileCount=''; Folder_Accessible=''; User_InAcl=''; User_AclRights=''; Folder_Error='' }
    $fs = if (-not $SkipFolderStats -and $u.homeDirectory) {
        try   { Get-FolderStats -FolderPath $u.homeDirectory -SamAccount $u.SamAccountName -DeepScanEnabled $DeepScan.IsPresent -CheckAcl (-not $SkipPermissionCheck.IsPresent) }
        catch { $errCount++; $emptyFs.Folder_Error = "Unexpected: $($_.Exception.Message)"; $emptyFs }
    } else { $emptyFs }

    # Serialise each source to a readable "DRIVE=\\path [note]" string for the spreadsheet
    $adStr  = ($adMaps   | ForEach-Object { "$($_.Drive)=$($_.Path)" }) -join ' | '
    $lsStr  = ($logonMaps | ForEach-Object { if ($_.Drive -and $_.Path) { "$($_.Drive)=$($_.Path) [$($_.Method)]" } else { "Not found: $($_.ScriptFile)" } }) -join ' | '
    $gpoStr = ($gpoMaps  | ForEach-Object { "$($_.Drive)=$($_.Path) $(if ($_.HasFilters) {'[TARGETED]'} else {'[ALL_USERS]'}) [GPO:$($_.GPO_Guid.Substring(0,[Math]::Min(8,$_.GPO_Guid.Length)))...]" }) -join ' | '
    $regStr = ($regMaps  | ForEach-Object { "$($_.Drive)=$($_.Path)" }) -join ' | '
    $sources = @(if ($adMaps) {'AD'}; if ($logonMaps) {'LogonScript'}; if ($gpoMaps) {'GPO'}; if ($regMaps) {'Registry'})

    $rows.Add([PSCustomObject][ordered]@{
        # Who
        SamAccountName       = $u.SamAccountName
        DisplayName          = $u.DisplayName
        Email                = $u.mail
        Department           = $u.Department
        Enabled              = if ($u.Enabled) { 'Enabled' } else { 'DISABLED' }
        Description          = $u.Description
        LastLogonDate        = if ($u.lastLogonDate)   { $u.lastLogonDate.ToString('yyyy-MM-dd')   } else { '' }
        PasswordLastSet      = if ($u.PasswordLastSet) { $u.PasswordLastSet.ToString('yyyy-MM-dd') } else { '' }
        DistinguishedName    = $u.distinguishedName
        # Raw AD drive attributes (useful for cross-referencing)
        AD_HomeDrive         = $u.homeDrive
        AD_HomeDirectory     = $u.homeDirectory
        AD_ProfilePath       = $u.profilePath
        AD_ScriptPath        = $u.scriptPath
        # Mapping summary
        Total_MappingCount   = $adMaps.Count + $logonMaps.Count + $gpoMaps.Count + $regMaps.Count
        Mapping_Sources      = $sources -join '; '
        # Per-source detail
        AD_Mappings          = $adStr
        AD_Count             = $adMaps.Count
        LogonScript_Mappings = $lsStr
        LogonScript_Count    = $logonMaps.Count
        LogonScript_HasPath  = [bool]$u.scriptPath
        GPO_Mappings         = $gpoStr
        GPO_AllUsers_Count   = ($gpoMaps | Where-Object { -not $_.HasFilters } | Measure-Object).Count
        GPO_Targeted_Count   = ($gpoMaps | Where-Object { $_.HasFilters } | Measure-Object).Count
        Registry_Mappings    = $regStr
        Registry_Count       = $regMaps.Count
        # Folder health
        Folder_Exists        = $fs.Folder_Exists
        Folder_LastModified  = $fs.Folder_LastModified
        Folder_LatestFile    = $fs.Folder_LatestFile
        Folder_FileCount     = $fs.Folder_FileCount
        Folder_Accessible    = $fs.Folder_Accessible
        User_InAcl           = $fs.User_InAcl
        User_AclRights       = $fs.User_AclRights
        Folder_Error         = $fs.Folder_Error
    })
}

# ── Export ────────────────────────────────────────────────────────────────────

# Create output directory if it doesn't exist yet
$csvDir = Split-Path $OutputCsv -Parent
if ($csvDir -and -not (Test-Path $csvDir)) { New-Item -ItemType Directory -Path $csvDir -Force | Out-Null }

$rows | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
Log "CSV saved: $OutputCsv  ($($rows.Count) rows)"

if ($ExcelOutput) {
    if (Get-Module -ListAvailable ImportExcel -EA SilentlyContinue) {
        try {
            $xl = [IO.Path]::ChangeExtension($OutputCsv, '.xlsx')
            $rows | Export-Excel -Path $xl -WorksheetName 'HomeDriveAudit' `
                -AutoFilter -FreezeTopRow -BoldTopRow -AutoSize `
                -TableName 'HomeDriveAudit' -TableStyle Medium2
            Log "Excel saved: $xl"
        } catch { Log "Excel export failed: $_" 'WARN' }
    } else { Log "ImportExcel not installed: Install-Module ImportExcel -Scope CurrentUser" 'WARN' }
}

# ── Summary ───────────────────────────────────────────────────────────────────

Log ""
Log "── Summary ──────────────────────────────────────────────────────────"
Log "  Total audited            : $total    |  No mappings: $(@($rows | Where-Object { $_.Total_MappingCount -eq 0 }).Count)    |  Multiple sources: $(@($rows | Where-Object { ($_.Mapping_Sources -split ';').Count -gt 1 }).Count)"
Log "  AD homeDirectory set     : $(@($rows | Where-Object AD_HomeDirectory).Count)    |  AD profilePath set: $(@($rows | Where-Object AD_ProfilePath).Count)"
Log "  Script path in AD        : $(@($rows | Where-Object LogonScript_HasPath).Count)    |  Scripts with drive maps: $(@($rows | Where-Object { $_.LogonScript_Count -gt 0 }).Count)"
Log "  GPO all-user entries     : $(($allGpoMaps | Where-Object { -not $_.HasFilters } | Measure-Object).Count)    |  GPO targeted (ILT): $(($allGpoMaps | Where-Object HasFilters | Measure-Object).Count)"
Log "  Registry mappings found  : $(@($rows | Where-Object { $_.Registry_Count -gt 0 }).Count)"
Log "  Home folders exist       : $(@($rows | Where-Object { $_.Folder_Exists -eq $true }).Count)    |  Missing: $(@($rows | Where-Object { $_.AD_HomeDirectory -and $_.Folder_Exists -eq $false }).Count)    |  User not in ACL: $(@($rows | Where-Object { $_.Folder_Exists -eq $true -and $_.User_InAcl -eq $false }).Count)"
Log "  Errors                   : $errCount"
Log "─────────────────────────────────────────────────────────────────────"
