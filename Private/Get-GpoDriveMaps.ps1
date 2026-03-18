# Get-GpoDriveMaps.ps1
#
# Scans the SYSVOL for Group Policy Preference drive map entries (Drives.xml).
# This is a domain-wide scan done once — results are shared across all users.
#
# Each entry in the result includes:
#   GPO_Guid   — The GUID of the GPO that contains this drive map
#   Drive      — Drive letter, e.g. H:
#   Path       — UNC path, e.g. \\fileserver\homes$\%username%
#   Label      — Display label (if set)
#   Action     — C=Create  U=Update  D=Delete  R=Replace
#   HasFilters — $true if item-level targeting is set; the entry may not apply to every user
#   XmlSource  — Full path to the Drives.xml file this came from
#
# Parameters:
#   SysvolBase — Optional override for the SYSVOL root, e.g. \\corp.local\SYSVOL\corp.local
#                Auto-detected from the current domain if not supplied.

function Get-GpoDriveMaps {
    param(
        [string] $SysvolBase
    )

    $maps = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Auto-detect SYSVOL path from the domain the running machine is joined to.
    if ([string]::IsNullOrWhiteSpace($SysvolBase)) {
        try {
            $dom       = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
            $SysvolBase = "\\$($dom.Name)\SYSVOL\$($dom.Name)"
        } catch {
            Log "Cannot auto-detect SYSVOL path: $_" 'WARN'
            return $maps
        }
    }

    $policiesPath = Join-Path $SysvolBase 'Policies'

    if (-not (Test-Path $policiesPath -EA SilentlyContinue)) {
        Log "SYSVOL Policies folder not reachable: $policiesPath" 'WARN'
        return $maps
    }

    # Find every Drives.xml across all GPO subfolders.
    $xmlFiles = @(Get-ChildItem -Path $policiesPath -Recurse -Filter 'Drives.xml' -EA SilentlyContinue)
    Log "  Found $($xmlFiles.Count) Drives.xml file(s) in SYSVOL"

    foreach ($xf in $xmlFiles) {
        try {
            [xml]$doc = Get-Content -LiteralPath $xf.FullName -EA Stop

            # Extract the GPO GUID from the folder path — it's the {xxxxxxxx-...} segment.
            $guid = if ($xf.FullName -match '\{([0-9A-Fa-f\-]{36})\}') { $Matches[1] } else { 'Unknown' }

            foreach ($drv in @($doc.Drives.Drive)) {
                if (-not $drv) { continue }

                $p = $drv.Properties
                $maps.Add([PSCustomObject]@{
                    GPO_Guid   = $guid
                    Drive      = if ($p.letter) { "$($p.letter.ToUpper()):" } else { '' }
                    Path       = if ($p.path)   { $p.path   } else { '' }
                    Label      = if ($p.label)  { $p.label  } else { '' }
                    Action     = if ($p.action) { $p.action } else { '' }
                    HasFilters = ($null -ne $drv.Filters -and $drv.Filters.HasChildNodes)
                    XmlSource  = $xf.FullName
                })
            }
        } catch {
            Log "Drives.xml parse error [$($xf.FullName)]: $_" 'WARN'
        }
    }

    return $maps
}
