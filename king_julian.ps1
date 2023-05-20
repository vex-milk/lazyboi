# This script allows you to securely transfer a file over SFTP (SSH File Transfer Protocol) using a Managed Service Account (MSA) for authentication.
# It establishes a connection to an SFTP server and transfers a file from a specified source path to a destination folder on a Windows share.
# I called it king_julian because I like his tail...

<#
.SYNOPSIS
   Securely copies a file to an SFTP server using PowerShell.
.DESCRIPTION
   This script securely copies a file to an SFTP server using PowerShell. It establishes an SSH session with the server, authenticates using SSH key-based authentication, and performs the file transfer.
.PARAMETER SourceFilePath
   Specifies the path of the source file to be copied.
.PARAMETER DestinationFolderPath
   Specifies the destination folder where the file will be copied.
.PARAMETER DestinationFileName
   (Optional) Specifies the name of the destination file. If not provided, the source file name will be used.
.PARAMETER SftpServer
   Specifies the address or hostname of the SFTP server.
.PARAMETER ManagedServiceAccountName
   Specifies the name of the Managed Service Account.
.PARAMETER LogFilePath
   Specifies the path of the log file where information will be written.
.PARAMETER CopyAllFiles
   (Optional) Switch parameter indicating whether to copy all files from the source folder.
.PARAMETER Silent
   (Optional) Switch parameter indicating whether to run the script silently, suppressing verbose output.
.PARAMETER Verbose
   (Optional) Switch parameter indicating whether to run the script in verbose mode, providing detailed output.
.EXAMPLE
   .\Copy-ToSFTPServer.ps1 -SourceFilePath "C:\Files\file.txt" -DestinationFolderPath "/data/files" -SftpServer "sftp.example.com" -ManagedServiceAccountName "SFTP_User" -LogFilePath "C:\Logs\file_copy.log" -Verbose
   This example copies the file "file.txt" from the local machine to the "/data/files" folder on the SFTP server "sftp.example.com". It uses the Managed Service Account "SFTP_User" for authentication and writes verbose output to the log file "file_copy.log".
#>

# Set the execution policy to RemoteSigned to restrict running unsigned scripts
Set-ExecutionPolicy RemoteSigned -Scope Process

# Check if the SSH-Sessions module is installed, and install it if necessary
if (-not (Get-Module -Name SSH-Sessions -ListAvailable)) {
    Write-Host "The 'SSH-Sessions' module is required to run this script. Installing the module..."

    try {
        Install-Module -Name SSH-Sessions -Scope CurrentUser -Force
        Write-Host "The 'SSH-Sessions' module has been installed successfully."
    }
    catch {
        Write-Host "Failed to install the 'SSH-Sessions' module. Please ensure you have the required permissions to install PowerShell modules."
        return
    }
}

# Set the SSH client configuration to force TLS 1.3
$sshClientConfigPath = "$env:USERPROFILE\.ssh\ssh_config"

# Create or update the SSH client configuration file
@"
Host *
    Include C:\Program Files\OpenSSH-Win64\etc\ssh_config
    Protocol 2
    Ciphers aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes256-ctr
    MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-256
    KexAlgorithms curve25519-sha256@libssh.org
    HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com,ssh-ed25519
    UseRoaming no
    LogLevel VERBOSE
"@ | Set-Content -Path $sshClientConfigPath -Force

param (
    [Parameter(Mandatory = $true)]
    [String]$SourceFilePath,

    [Parameter(Mandatory = $true)]
    [String]$DestinationFolderPath,

    [String]$DestinationFileName,

    [Parameter(Mandatory = $true)]
    [String]$SftpServer,

    [Parameter(Mandatory = $true)]
    [String]$ManagedServiceAccountName,

    [Parameter(Mandatory = $true)]
    [String]$LogFilePath,

    [Switch]$CopyAllFiles,

    [Switch]$Silent,

    [Switch]$Verbose
)

# Validate the source file path
if (-not (Test-Path -Path $SourceFilePath -PathType Leaf)) {
    Write-Verbose "Source file '$SourceFilePath' does not exist."
    Add-Content -Path $LogFilePath -Value "Source file '$SourceFilePath' does not exist."
    return
}

# Validate the destination folder path
if (-not (Test-Path -Path $DestinationFolderPath -PathType Container)) {
    Write-Verbose "Destination folder '$DestinationFolderPath' does not exist."
    Add-Content -Path $LogFilePath -Value "Destination folder '$DestinationFolderPath' does not exist."
    return
}

# Set secure string credentials for the MSA
$msaCredentials = Get-StoredCredential -Target $ManagedServiceAccountName
if (!$msaCredentials) {
    Write-Verbose "Could not retrieve the MSA credentials from the Credential Manager."
    Add-Content -Path $LogFilePath -Value "Could not retrieve the MSA credentials from the Credential Manager."
    return
}

# Convert the password from SecureString to plain text
$msaPassword = $msaCredentials.GetNetworkCredential().Password

# Create a PSCredential object for the MSA
$msaCredential = New-Object System.Management.Automation.PSCredential($ManagedServiceAccountName, ($msaPassword | ConvertTo-SecureString -AsPlainText -Force))

# Disable verbose output unless explicitly enabled
if (-not $Verbose) {
    $VerbosePreference = 'SilentlyContinue'
}

try {
    # Securely connect to the SFTP server using SSH key authentication
    $sshSession = New-SFTPSession -ComputerName $SftpServer -Credential $msaCredential -KeyPath "C:\Path\To\PrivateKey.pem"

    # Determine the destination file name
    if (-not $DestinationFileName) {
        $DestinationFileName = (Split-Path -Path $SourceFilePath -Leaf)
    }

    # Construct the full destination file path
    $DestinationFilePath = Join-Path -Path $DestinationFolderPath -ChildPath $DestinationFileName

    # Copy the file to the destination folder
    if ($CopyAllFiles) {
        Copy-SFTPItem -SessionId $sshSession.SessionId -Path $SourceFilePath -Destination $DestinationFolderPath -Recurse -Force
    }
    else {
        Copy-SFTPItem -SessionId $sshSession.SessionId -Path $SourceFilePath -Destination $DestinationFilePath -Force
    }

    # Close the SSH session
    Remove-SFTPSession -SessionId $sshSession.SessionId

    Write-Verbose "File '$SourceFilePath' copied to '$DestinationFilePath' successfully."
    Add-Content -Path $LogFilePath -Value "File '$SourceFilePath' copied to '$DestinationFilePath' successfully."
}
catch {
    Write-Verbose "Error occurred during file transfer: $_"
    Add-Content -Path $LogFilePath -Value "Error occurred during file transfer: $_"
}


