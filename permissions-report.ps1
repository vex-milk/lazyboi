$FolderPath = Get-ChildItem -Directory -Path "C:\temp" -Recurse -Force
$Output = @()

# Calculate the total number of directories and access rules
$totalDirectories = $FolderPath.Count
$totalAccessRules = 0

# Initialize a counter for the progress
$currentItem = 0

ForEach ($Folder in $FolderPath) {
    $ErrorActionPreference = "Stop"  # Set to stop on error

    # Handling errors when retrieving ACL information
    try {
        $Acl = Get-Acl -Path $Folder.FullName
        $ErrorActionPreference = "Continue"  # Set back to default behavior
    }
    catch {
        $ErrorActionPreference = "Continue"  # Set back to default behavior

        # Create a custom object to store error information
        $ErrorProperties = [ordered]@{
            'Folder Name'  = $Folder.FullName
            'Error'        = $_.Exception.Message
        }
        $Output += New-Object -TypeName PSObject -Property $ErrorProperties

        Write-Error "Error retrieving ACL for folder $($Folder.FullName): $($_.Exception.Message)"
        continue  # Skip to the next iteration after handling the error
    }

    ForEach ($Access in $Acl.Access) {
        $Properties = [ordered]@{
            'Folder Name'  = $Folder.FullName
            'Group/User'   = $Access.IdentityReference
            'Permissions'  = $Access.FileSystemRights
            'Inherited'    = $Access.IsInherited
        }
        $Output += New-Object -TypeName PSObject -Property $Properties

        # Increment the progress counter and update the progress bar
        $totalAccessRules++
        $currentItem++
        $progressPercentage = ($currentItem / ($totalDirectories + $totalAccessRules)) * 100
        Write-Progress -Activity "Analyzing folder permissions" -Status "Progress" -PercentComplete $progressPercentage
    }
}

# Clear the progress bar once the analysis is complete
Write-Progress -Activity "Analyzing folder permissions" -Completed

# Prompt the user to choose the export format
$choice = Read-Host "Choose the export format (CSV, XML, or JSON)"
switch ($choice.ToUpper()) {
    'CSV' {
        $csvFilePath = Join-Path -Path $env:TEMP -ChildPath "FolderPermissionsReport.csv"
        $Output | Export-Csv -Path $csvFilePath -NoTypeInformation
        Write-Host "The report has been exported as CSV to: $csvFilePath"
    }
    'XML' {
        $xmlFilePath = Join-Path -Path $env:TEMP -ChildPath "FolderPermissionsReport.xml"
        $Output | Export-Clixml -Path $xmlFilePath
        Write-Host "The report has been exported as XML to: $xmlFilePath"
    }
    'JSON' {
        $jsonFilePath = Join-Path -Path $env:TEMP -ChildPath "FolderPermissionsReport.json"
        $Output | ConvertTo-Json | Out-File -FilePath $jsonFilePath
        Write-Host "The report has been exported as JSON to: $jsonFilePath"
    }
    default {
        Write-Host "Invalid choice. The report will be displayed in Out-GridView."
        $Output | Out-GridView
    }
}
