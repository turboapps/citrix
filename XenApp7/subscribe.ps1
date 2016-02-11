# Licensed under the Apache License, Version 2.0
# http://www.apache.org/licenses/LICENSE-2.0

<#

.SYNOPSIS

Subscribes a XenApp server to the specified user, org, or channel and adds the subscribed applications to the specified delivery group.

.DESCRIPTION

Requires XenApp 7.*

.PARAMETER subscription

The name of the user, org, or channel to subscribe to.

.PARAMETER deliveryGroup

The name of the XenApp delivery group to add the applications to.

.PARAMETER server

The name of a remote XenApp server.

.PARAMETER user

The Turbo.net user with access to the subscription. If not specified then will be prompted if necessary.

.PARAMETER password

The password for the Turbo.net user. If not specified then will be prompted if necessary.

#>


[CmdletBinding()]
param
(
    [Parameter(Mandatory=$True,ValueFromPipeline=$True,ValueFromPipelineByPropertyName=$True,HelpMessage="The name of the user, org, or channel to subscribe to")]
    [string] $subscription,
    [Parameter(Mandatory=$True,ValueFromPipeline=$True,ValueFromPipelineByPropertyName=$True,HelpMessage="The name of the XenApp delivery group to add the applications to")]
    [string] $deliveryGroup,
    [Parameter(Mandatory=$False,ValueFromPipeline=$True,ValueFromPipelineByPropertyName=$True,HelpMessage="The name of a remote XenApp server")]
    [string] $server,
    [Parameter(Mandatory=$False,ValueFromPipeline=$True,ValueFromPipelineByPropertyName=$True,HelpMessage="The Turbo.net user with access to the subscription")]
    [string] $user,
    [Parameter(Mandatory=$False,ValueFromPipeline=$True,ValueFromPipelineByPropertyName=$True,HelpMessage="The password for the Turbo.net user")]
    [string] $password
)

Write-Host
Write-Host "Subscribe to $subscription..."


function LoginIf([string]$user, [string]$password = "", [string]$server = "") {
    
    if($server) {
        # send off to the server to perform
        Invoke-Command -ComputerName $server `
            -ArgumentList $user, $password `
            -ScriptBlock ${function:LoginIf}
    }
    else {
        # perform locally
        $login = & turbo login --format=json | ConvertFrom-Json

        if($login.result.exitCode -eq 0 -and $user -and $login.result.user.login -ne $user) {
            # wrong user so re-login
            $login.result.exitCode = -1
        }

        while($login.result.exitCode -ne 0)
        {
            if(-not $password) {
                $cred = Get-Credential -UserName $user -Message "Enter your Turbo.net password"
                if(-not $cred) {
                    $false
                    return
                }
                $password = $cred.GetNetworkCredential().Password
            }
            $login = & turbo login --format=json $user $password | ConvertFrom-Json
            $password = ""
        }

        $true
    }
}

function Subscribe([string]$subscription, [string]$deliveryGroup, [string]$server = "") {
    
    if($server) {
        # send off to the server to perform
        Invoke-Command -ComputerName $server `
            -ArgumentList $subscription, $deliveryGroup `
            -ScriptBlock ${function:Subscribe}
    }
    else {
        # perform locally
        Add-PSSnapin Citrix* -ErrorAction SilentlyContinue # may already be loaded

        $events = & turbo subscribe $subscription --all-users --format=rpc | ConvertFrom-Json
        $installEvents = $events | where { $_.event -and $_.event -eq "install" }
        if(-not $installEvents) {
            $events | where { $_.event -and $_.event -eq "error" } | foreach { Write-Output $_.message }
            return
        }
    
        # loop over all the installed apps
        $linkDir = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Turbo.net"
        $shell = New-Object -ComObject WScript.Shell
        foreach ($event in $installEvents) {
            $name = $event.name
    
            # get values out of the shortcuts
            $linkPath = "$linkDir\$name.lnk"
            $lnk = $shell.CreateShortcut($linkPath)
            $target = $lnk.TargetPath
            $params = $lnk.Arguments
            $icon = $lnk.IconLocation -split "," # string comes in format "path,index"
    
            # trim off illegal chars
            $xaName = $name -replace "[\\\/;:#.*?=<>\[\]()]", ""

            $app = Get-BrokerApplication -name $xaName -ErrorAction SilentlyContinue
            if(-not $app) {
                $ctxIcon = Get-CtxIcon -FileName $icon[0] -Index $icon[1]
                $brokerIcon = New-BrokerIcon -EncodedIconData $ctxIcon.EncodedIconData

                $app = New-BrokerApplication `
                    -Name $xaName `
                    -CommandLineExecutable $target `
                    -CommandLineArguments $params `
                    -DesktopGroup $deliveryGroup `
                    -IconUid $brokerIcon.Uid

                if($app) {
                    Write-Output "$xaName added"
                }
            }
        }
    }
}

# login if necessary
$login = LoginIf $user $password $server
if(-not $login) {
    exit -1
}
   
# subscribe
Subscribe $subscription $deliveryGroup $server
