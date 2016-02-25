# Licensed under the Apache License, Version 2.0
# http://www.apache.org/licenses/LICENSE-2.0

<#

.SYNOPSIS

Builds the turbocitrix images.

.PARAMETER certPath

The path to a certificate to sign the scripts. If blank, no signing is performed.

.PARAMETER certPassword

The password for the certificate if necessary.

.PARAMETER push

If the image should be pushed on successful build.

#>


[CmdletBinding()]
param
(
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The path to a certificate to sign the scripts")]
    [string] $certPath,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The password for the certificate")]
    [string] $certPassword,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="If the image should be pushed on successful build")]
    [switch] $push
)


# stage the build
$root = "$PSScriptRoot\.."
$stage = "$root\stage"
$scripts = "$stage\scripts"

Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
$ret = New-Item $stage -ItemType Directory

ForEach ($item in $(Get-ChildItem $root -Directory)) {
    # copy each directory, skipping over any lone files in the root
    if($item.Name -eq "stage") {
        # skip
    }
    elseif($item.Name -eq "build") {
        # find all turbo.me files, copy foo\turbo.me -> stage\foo.me to flatten the structure and to be under the script dir so can mount to cherry pick the scripts we want
        ForEach ($turbome in $(Get-ChildItem $item.FullName -Filter "turbo.me" -Recurse)) {
            $dirname = Split-Path -leaf $turbome.DirectoryName
            Copy-Item $turbome.FullName "$stage\$dirname.me"
        }
    }
    else {
        Copy-Item $item.FullName $scripts\$item -Recurse -Container
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
$tag = Get-Date -Format yyyy.MM.dd
ForEach ($turbome in $(Get-ChildItem $stage -Filter "*.me")) {
    $path = $turbome.FullName
    Write-Host "Building $path"

    & turbo build $path $tag --mount=$scripts=C:\Scripts --overwrite 
    if($LASTEXITCODE -ne 0) {
        Write-Error "Error building $path"
        Exit $LASTEXITCODE
    }
    
    # push if successful
    if($push.IsPresent) {
        $name = $turbome.BaseName
        $repo = "turbocitrix/${name}:$tag"
        Write-Host "Pushing $repo"

        & turbo push $repo
        if($LASTEXITCODE -ne 0) {
            Write-Error "Error pushing $repo"
            Exit $LASTEXITCODE
        }
    }
}