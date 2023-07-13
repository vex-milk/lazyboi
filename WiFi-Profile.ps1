<#
This PowerShell script generates a Wi-Fi profile XML file based on the provided configuration.
The generated XML includes settings such as the profile name, SSID, connection type, encryption, and authentication details.
The XML is saved to a file in the user's documents directory.
Finally, the script adds the Wi-Fi profile to the Windows WLAN profiles using the netsh wlan add profile command.

Note:
To run this script successfully, ensure you have the necessary certificate and appropriate permissions to modify WLAN profiles.
#>

# PowerShell script to generate a Wi-Fi profile XML file and add it to the Windows WLAN profiles.

# Define the name of the Wi-Fi profile.
$profileName = "MyWiFiProfile"

# Define the SSID (network name) of the Wi-Fi network.
$ssid = "YourSSID"

# Define the thumbprint of a certificate used for authentication.
$certificateThumbprint = "CertificateThumbprint"

# Build the Wi-Fi Profile XML document.
$wifiProfileXml = @"
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$profileName</name>
    <SSIDConfig>
        <SSID>
            <name>$ssid</name>
        </SSID>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>auto</connectionMode>
    <MSM>
        <security>
            <authEncryption>
                <authentication>WPA2</authentication>
                <encryption>AES</encryption>
                <useOneX>true</useOneX>
            </authEncryption>
            <OneX xmlns="http://www.microsoft.com/networking/OneX/v1">
                <authMode>machineOrUser</authMode>
                <EAPConfig>
                    <EapHostConfig xmlns="http://www.microsoft.com/provisioning/EapHostConfig">
                        <EapMethod>
                            <Type xmlns="http://www.microsoft.com/provisioning/EapCommon">$certificateThumbprint</Type>
                            <VendorId xmlns="http://www.microsoft.com/provisioning/EapCommon">0</VendorId>
                            <VendorType xmlns="http://www.microsoft.com/provisioning/EapCommon">0</VendorType>
                            <AuthorId xmlns="http://www.microsoft.com/provisioning/EapCommon">0</AuthorId>
                        </EapMethod>
                    </EapHostConfig>
                </EAPConfig>
            </OneX>
        </security>
    </MSM>
</WLANProfile>
"@

# Define the file path where the Wi-Fi profile XML file will be stored.
$wifiProfilePath = "$env:USERPROFILE\Documents\$profileName.xml"

# Store the Wi-Fi Profile XML to a file.
$wifiProfileXml | Out-File -FilePath $wifiProfilePath -Encoding UTF8

# Add the Wi-Fi Profile to the Windows WLAN profiles.
netsh wlan add profile filename="$wifiProfilePath"

"@

$wifiProfilePath = "$env:USERPROFILE\Documents\$profileName.xml"
$wifiProfileXml | Out-File -FilePath $wifiProfilePath -Encoding UTF8

netsh wlan add profile filename="$wifiProfilePath"
