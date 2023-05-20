# This script allows you to securely transfer a file over SFTP (SSH File Transfer Protocol) using a Managed Service Account (MSA) for authentication.
# It establishes a connection to an SFTP server and transfers a file from a specified source path to a destination folder on a Windows share.

# Parameters:

# SourceFilePath: The path to the source file that needs to be transferred.
# DestinationFolderPath: The destination folder path on the Windows share where the file should be transferred.
# DestinationFileName: The name of the destination file.
# SftpServer: The address of the SFTP server.
# ManagedServiceAccountName: The name of the Managed Service Account (MSA) stored in the Windows Credential Manager.
# LogFilePath: The path to the log file where the script will record transfer details and errors.
# Silent (Switch): Suppresses all script output except for error messages.
# Verbose (Switch): Enables detailed script output.

# Example
# Transfer-SFTPFile -SourceFilePath "C:\Path\To\Source\File.zip" -DestinationFolderPath "\\Server\Share\Folder" -DestinationFileName "File.zip" -SftpServer "sftp.example.com" -ManagedServiceAccountName "ManagedServiceAccount" -LogFilePath "C:\Path\To\Log\transfer.log" -Verbose

# Notes:
# The script requires the SSHUtils module, which can be installed using the Install-Module command.
# Ensure that the Managed Service Account (MSA) credentials are stored in the Windows Credential Manager.
# The script uses TLS 1.3 for secure communication with the SFTP server.
# Transfer details and any encountered errors will be logged in the specified log file.

<#
.SYNOPSIS
    Transfer a file over SFTP using a Managed Service Account (MSA) for authentication.

.DESCRIPTION
    This script establishes an SSH session to the SFTP server using the provided Managed Service Account (MSA) credentials
    and transfers a file from the source path to the specified destination folder.

.PARAMETER SourceFilePath
    The path to the source file that needs to be transferred.

.PARAMETER DestinationFolderPath
    The destination folder path on the Windows share where the file should be transferred.

.PARAMETER DestinationFileName
    The name of the destination file.

.PARAMETER SftpServer
    The address of the SFTP server.

.PARAMETER ManagedServiceAccountName
    The name of the Managed Service Account (MSA) stored in the Windows Credential Manager.

.PARAMETER LogFilePath
    The path to the log file where the script will record transfer details and errors.

.PARAMETER Silent
    Suppresses all script output except for error messages.

.PARAMETER Verbose
    Enables detailed script output.

.EXAMPLE
    Transfer-SFTPFile -SourceFilePath "C:\Path\To\Source\File.zip" -DestinationFolderPath "\\Server\Share\Folder" -DestinationFileName "File.zip" -SftpServer "sftp.example.com" -ManagedServiceAccountName "ManagedServiceAccount" -LogFilePath "C:\Path\To\Log\transfer.log" -Verbose

.NOTES
    - This script requires the SSHUtils module. Install the module using the following command:
        Install-Module -Name SSHUtils

    - Ensure that the Managed Service Account (MSA) credentials are stored in the Windows Credential Manager.

    - The script uses TLS 1.3 for secure communication with the SFTP server.

    - The log file will contain transfer details and any encountered errors.
#>

param (
    [Parameter(Mandatory = $true)]
    [String]$SourceFilePath,

    [Parameter(Mandatory = $true)]
    [String]$DestinationFolderPath,

    [Parameter(Mandatory = $true)]
    [String]$DestinationFileName,

    [Parameter(Mandatory = $true)]
    [String]$SftpServer,

    [Parameter(Mandatory = $true)]
    [String]$ManagedServiceAccountName,

    [Parameter(Mandatory = $true)]
    [String]$LogFilePath,

    [Switch]$Silent,

    [Switch]$Verbose
)

if ($Silent) {
    $VerbosePreference = 'SilentlyContinue'
}

if ($Verbose) {
    $VerbosePreference = 'Continue'
}

try {
    # Get the MSA credentials from the Windows Credential Manager
    $msaCredentials = Get-StoredCredential -Target $ManagedServiceAccountName

    if (!$msaCredentials) {
        Write-Verbose "Could not retrieve the MSA credentials from the Credential Manager."
        Add-Content -Path $LogFilePath -Value "Could not retrieve the MSA credentials from the Credential Manager."
        return
    }

    # Convert the password from SecureString to plain text
    $msaPassword = $msaCredentials.GetNetworkCredential().Password

    # Create a PSCredential object for the MSA
    $msaCredential = New-Object System.Management.Automation.PSCredential ($ManagedServiceAccountName, ($msaPassword | ConvertTo-SecureString -AsPlainText -Force))

    # Create SSH session options with TLS 1.3 enabled and strict host key checking
    $sessionOptions = New-SshSessionOption -Protocol SSH2 -Ciphers aes256-ctr,aes192-ctr,aes128-ctr -
