# Get-FolderStats.ps1
#
# Checks whether a home directory folder exists, is accessible, and how recently
# it was modified. Optionally counts files and reads the ACL to verify the user
# has an explicit permission entry.
#
# Parameters:
#   FolderPath      — UNC or local path to check, e.g. \\fileserver\homes$\jsmith
#   SamAccount      — Username to look for in the ACL, e.g. jsmith
#   DeepScanEnabled — $true to recurse the whole tree (slow); $false for top-level only
#   CheckAcl        — $true to inspect the ACL; $false to skip it

function Get-FolderStats {
    param(
        [string] $FolderPath,
        [string] $SamAccount,
        [bool]   $DeepScanEnabled,
        [bool]   $CheckAcl
    )

    # Default result — all fields empty so blank cells appear in the spreadsheet
    # when a folder path was never set in AD.
    $out = [PSCustomObject]@{
        Folder_Exists        = ''
        Folder_LastModified  = ''
        Folder_LatestFile    = ''
        Folder_FileCount     = ''
        Folder_Accessible    = ''
        User_InAcl           = ''
        User_AclRights       = ''
        Folder_Error         = ''
    }

    if ([string]::IsNullOrWhiteSpace($FolderPath)) { return $out }

    # Step 1 — Does the path exist at all?
    try {
        if (-not (Test-Path -LiteralPath $FolderPath -EA Stop)) { return $out }
    } catch {
        $out.Folder_Error = "Test-Path: $($_.Exception.Message)"
        return $out
    }

    $out.Folder_Exists = $true

    # Step 2 — Get the folder's own last-write timestamp
    try {
        $dir = Get-Item -LiteralPath $FolderPath -EA Stop
        $out.Folder_LastModified = $dir.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        $out.Folder_Accessible   = $true
    } catch {
        $out.Folder_Error = "Get-Item: $($_.Exception.Message)"
        return $out
    }

    # Step 3 — Count files and find the most recently modified one.
    #           With -DeepScan this recurses the whole tree; otherwise top-level only.
    try {
        $gcArgs = @{ LiteralPath = $FolderPath; File = $true; ErrorAction = 'SilentlyContinue' }
        if ($DeepScanEnabled) { $gcArgs['Recurse'] = $true }

        $files = Get-ChildItem @gcArgs | Sort-Object LastWriteTime -Descending

        $out.Folder_FileCount  = if ($files) { ($files | Measure-Object).Count } else { 0 }
        $out.Folder_LatestFile = if ($files) { $files[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
    } catch {
        $out.Folder_Error += " FileEnum: $($_.Exception.Message)"
    }

    # Step 4 — Check the ACL for an entry matching the user.
    #           Matches DOMAIN\username or just username (local/simple accounts).
    if ($CheckAcl) {
        try {
            $rights = @(
                (Get-Acl -LiteralPath $FolderPath -EA Stop).Access |
                Where-Object {
                    $_.IdentityReference.Value -match "\\$([regex]::Escape($SamAccount))$" -or
                    $_.IdentityReference.Value -ieq $SamAccount
                } |
                ForEach-Object { "$($_.FileSystemRights) [$($_.AccessControlType)]" }
            )

            $out.User_InAcl     = ($rights.Count -gt 0)
            $out.User_AclRights = $rights -join ' | '
        } catch {
            $out.Folder_Error += " ACL: $($_.Exception.Message)"
        }
    }

    return $out
}
