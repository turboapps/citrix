# Licensed under the Apache License, Version 2.0
# http://www.apache.org/licenses/LICENSE-2.0

<#

.SYNOPSIS

Builds the citrix/turbocitrix-tools image.

.PARAMETER certPath

The path to a certificate to sign the scripts. If blank, no signing is performed.

.PARAMETER certPassword

The password for the certificate if necessary.

#>


[CmdletBinding()]
param
(
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The path to a certificate to sign the scripts")]
    [string] $certPath,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The password for the certificate")]
    [string] $certPassword
)


# copy scripts to stage
$stage = "$PSScriptRoot\stage"

Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

ForEach ($item in $(Get-ChildItem $PSScriptRoot)) {
    # copy each directory, skipping over any files in the root (just build stuff)
    if($item.PSIsContainer) {
        Copy-Item $item.FullName $stage\turbo\$item -Recurse -Container
    }
}

# sign scripts
if($certPath) {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certPath, $certPassword)
    if($cert) {
        ForEach ($item in $(Get-ChildItem $stage -Filter "*.ps1" -Recurse)) {
            Set-AuthenticodeSignature $item.FullName -Certificate $cert -IncludeChain All -TimestampServer http://timestamp.comodoca.com/authenticode
        }
    }
}

# build
$tag = Get-Date -Format yyyy.mm.dd
& turbo build $PSScriptRoot\turbo.me $tag --mount=$stage=C:\Scripts --overwrite 
