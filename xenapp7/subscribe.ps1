# Licensed under the Apache License, Version 2.0
# http://www.apache.org/licenses/LICENSE-2.0

<#

.SYNOPSIS

Subscribes a Citrix Virtual Apps or XenAPp server to the specified workspace/channel and adds the applications to the specified delivery group.

.DESCRIPTION

This cmdlet will automatically download and install the Turbo client if it isn't already installed for all users. This operation will require the 
script to be run as a system admin. 

Can install the client manually by downloading from http://start.turbo.net/install and running "turbo-plugin.exe --all-users --silent" as admin.

Requires Powershell 4.0+. Requires Citrix Virtual Apps 7.*.

.PARAMETER channel

The name of the channel to subscribe to.

.PARAMETER deliveryGroup

The name of the Citrix Virtual Apps delivery group to publish the applications to. If blank, no apps will be published.

.PARAMETER adminServer

The name of a Citrix Virtual Apps content delivery server. If this script is run from the content delivery server then this parameter is not required. 
If this parameter is used then the current user must be an appropriate admin in Citirix and be a member of the Windows "Remote Management Users" group.

.PARAMETER appServer

The name of a remote Citrix Virtual Apps server.

.PARAMETER user

The Turbo Server user with access to the channel. If not specified then will be prompted if necessary.

.PARAMETER password

The password for the Turbo Server user. If not specified then will be prompted if necessary.

.PARAMETER apiKey

The Turbo Server api key to be used instead of a user/password.

.PARAMETER allUsers

Applies the login to all users on the machine.

.PARAMETER cacheApps

The applications in the channel are to be cached locally. This could be a long operation.

.PARAMETER unsubscribe

Whether the channel is to be unsubscribed (rather than subscribed).

.PARAMETER waitOnExit

Waits for user confirmation after execution completes

#>


[CmdletBinding()]
param
(
    [Parameter(Mandatory=$True,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The name of the channel to subscribe to")]
    [string] $channel,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The name of the Citrix Virtual Apps delivery group to publish the applications to")]
    [string] $deliveryGroup,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The name of the Citrix Virtual Apps content delivery server")]
    [string] $adminServer,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The Turbo Server user with access to the channel")]
    [string] $user,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The password for the Turbo Server user")]
    [string] $password,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="A Turbo Server api key to be used instead of a user/password")]
    [string] $apiKey,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="Applies the login to all users on the machine")]
    [switch] $allUsers,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The channel is to be unsubscribed rather than subscribed")]
    [switch] $unsubscribe,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The applications in the channel are to be cached locally")]
    [switch] $cacheApps,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="Waits for user confirmation after execution completes")]
    [switch] $waitOnExit
)

# returns the path to turbo.exe or empty string if the client is not installed
function InstallTurboIf([string]$server = "") {
    if($server) {
        Invoke-Command -ComputerName $server -ScriptBlock ${function:InstallTurboIf}
    }
    else {
        # check if the client is installed for all users
        $relPath = "turbo\cmd\turbo.exe"
        $turboInstallFiles = ("$env:ProgramFiles\$relPath", "${env:ProgramFiles(x86)}\$relPath")
        foreach($turbo in $turboInstallFiles) {
            if($(Test-Path $turbo)) {
                return $turbo
            }
        }

        try {
            # download the latest client
            $turboInstaller = [System.IO.Path]::GetTempFileName()
            $ret = Invoke-WebRequest "http://start.turbo.net/install" -OutFile $turboInstaller
            if($(Get-Item $turboInstaller).Length -eq 0) {
                return ""
            }

            # rename as exe 
            ren $turboInstaller "$turboInstaller.exe"
            $turboInstaller = "$turboInstaller.exe"

            # install for all users
            # use Process.Start rather than Start-Process so that we don't hang on spawned child processes
            $p = New-Object System.Diagnostics.Process
            $p.StartInfo.FileName = $turboInstaller
            $p.StartInfo.Arguments = "--all-users --silent"
            $p.StartInfo.UseShellExecute = $false
            if(!$p.Start()) {
                return ""
            }

            $p.WaitForExit()

            if($p.ExitCode -ne 0) {
                Write-Error "There was an unexpected error installing the client. Please check the setup logs and confirm that you are running as an administrator."
                return "";
            }
        }
        finally {
            # clean up
            Remove-Item $turboInstaller
        }
        
        # confirm install is successful
        foreach($turbo in $turboInstallFiles) {
            if($(Test-Path $turbo)) {
                return $turbo
            }
        }

        return ""
    }
}


function LoginIf([string]$user, [string]$password, [string]$apikey, [bool]$allUsers, [string]$turbo, [string]$server = "") {
    
    if($server) {
        # send off to the server to perform
        Invoke-Command -ComputerName $server `
            -ArgumentList $user, $password, $apikey, $allUsers, $turbo `
            -ScriptBlock ${function:LoginIf}
    }
    else {
        $allUsersSwitch = ""
        if($allUsers) {
            $allUsersSwitch = "--all-users"
        }

        # use the api key if we have it
        if($apikey) {
            $ret = & $turbo login --api-key=$apikey $allUsersSwitch
            if($LASTEXITCODE -ne 0) {
                Write-Error "Invalid api key"
                return $false
            }
        }
        else {    
            # check if we're logged in (and as the correct user if necessary)
            $login = & $turbo login $allUsersSwitch --format=json | ConvertFrom-Json
            
            $success = $true
            if($LASTEXITCODE -eq 0 -and $user -and $login.result.user.login -ne $user) {
                # wrong user so re-login
                $success = $false
            }

            # loop until we have successful login
            while(-not $success)
            {
                if(-not $password) {
                    $cred = Get-Credential -UserName $user -Message "Enter your Turbo.net credentials"
                    if(-not $cred) {
                        return $false
                    }
                    $user = $cred.UserName
                    $password = $cred.GetNetworkCredential().Password
                }
                $login = & $turbo login --format=json $user $password $allUsersSwitch | ConvertFrom-Json
                if($LASTEXITCODE -eq 0) {
                    $success = $true
                }
                $password = ""
            }
        }

        return $true
    }
}

function Get-AppServers([string]$deliveryGroup, [string]$adminServer = "") {

    if($adminServer) {
        Invoke-Command -ComputerName $adminServer `
            -ArgumentList $deliveryGroup `
            -ScriptBlock ${function:Get-AppServers}
    }
    else {
    
        Write-Host " " # space things out a bit

        Add-PSSnapin Citrix* -ErrorAction SilentlyContinue # may already be loaded

        return Get-Brokermachine -DesktopGroupName $deliveryGroup
        
    }
}

function Subscribe([string]$subscription, [bool]$unsubscribe, [bool]$cacheApps, [string]$turbo, [string]$appServer, [bool]$invoke = $True) {
    
    if($invoke -and $appServer) {
        Invoke-Command -ComputerName $appServer `
            -ArgumentList $subscription, $unsubscribe, $cacheApps, $turbo, $appServer, $False `
            -ScriptBlock ${function:Subscribe}
    }
    else {
        # subscribe to the channel
        if(-not $unsubscribe) {
            Write-Host "`nSubscribe to $subscription on $appServer..."
            $events = & $turbo subscribe $subscription --all-users --format=rpc | ConvertFrom-Json
        }
        else {
            Write-Host "`nUnsubscribe from $subscription on $appServer..."
            $events = & $turbo unsubscribe $subscription --all-users --format=rpc | ConvertFrom-Json
        }
        if($LASTEXITCODE -ne 0) {
            $events | where { $_.event -and $_.event -eq "error" } | foreach { Write-Host $_.message }
            return $null
        }
        
        $installEvents = $events | where { $_.event -and $_.event -eq "install" }
        $uninstallEvents = $events | where { $_.event -and $_.event -eq "uninstall" }
        
        # show which apps were subscribe to
        foreach ($event in $installEvents) {
            $name = $event.name
            Write-Host "$name subscribed"
        }
        
        foreach ($event in $uninstallEvents) {
            $name = $event.name
            Write-Host "$name unsubscribed"
        }

        # pre-cache apps if necessary
        if($cacheApps) {
            Write-Host " " # space things out a bit
            Write-Host "Caching the subscription"

            $r = & $turbo subscription update $subscription --all-users
            if($LASTEXITCODE -ne 0) {
                Write-Host "Error while caching the subscription"
                $ret = $false
            }
        }
        
        # get values from installed shortcuts
        $installedApps = @()
        $linkDir = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs"
        $shell = New-Object -ComObject WScript.Shell
        foreach ($event in $installEvents) {
            $name = $event.name

            # get values out of the shortcuts
            $linkPath = "$linkDir\$name.lnk"
            $lnk = $shell.CreateShortcut($linkPath)
            $target = $lnk.TargetPath
            $params = $lnk.Arguments
            $icon = $lnk.IconLocation -split "," # string comes in format "path,index"
            
            $app = new-object psobject -property @{ Name = $name; Target = $target; Params = $params; Icon = $icon; Server = $appServer }
            $installedApps += ,$app
        }
        
        $uninstalledApps = $uninstallEvents | Select-Object -Property Name
        
        # return object with subscription events
        return new-object psobject -property @{InstalledApps = $installedApps; UninstalledApps = $uninstallEvents}
    }
}

function UpdateDeliveryGroup([string]$deliveryGroup, [array]$installedApps, [array]$uninstalledApps, [string]$adminServer = "") {

    if($adminServer) {
        Invoke-Command -ComputerName $adminServer `
            -ArgumentList $deliveryGroup, $installedApps, $uninstalledApps `
            -ScriptBlock ${function:UpdateDeliveryGroup}
    }
    else {
                
        # publish/unpublish the apps to the Citrix Virtual Apps server
        Write-Host " " # space things out a bit

        Add-PSSnapin Citrix* -ErrorAction SilentlyContinue # may already be loaded

        # publish new apps
        $ret = $true
        foreach ($event in $installedApps) {
        
            # check if the app is already here
            $name = $event.name -replace "[\\\/;:#.*?=<>\[\]()]", ""
            $app = Get-BrokerApplication -Name $name -AdminAddress $adminServer -ErrorAction SilentlyContinue
            if(-not $app) {
                # store the icon
                $ctxIcon = Get-BrokerIcon -ServerName $event.Server -FileName $event.Icon[0] -Index $event.Icon[1] -AdminAddress $adminServer
                $brokerIcon = New-BrokerIcon -EncodedIconData $ctxIcon.EncodedIconData -AdminAddress $adminServer

                # add the app
                $app = New-BrokerApplication `
                    -Name $name `
                    -CommandLineExecutable $event.Target `
                    -CommandLineArguments $event.Params `
                    -DesktopGroup $deliveryGroup `
                    -IconUid $brokerIcon.Uid `
                    -AdminAddress $adminServer

                if($app) {
                    Write-Host "$name published"
                }
                else {
                    Write-Host "$name was not published!"
                    $ret = $false
                }
            }
        }
        
        # unpublish those that were removed
        foreach ($event in $uninstalledApps) {
        
            $name = $event.Name -replace "[\\\/;:#.*?=<>\[\]()]", ""

            $app = Get-BrokerApplication -Name $name -AdminAddress $adminServer -ErrorAction SilentlyContinue
            if($app) {
                Remove-BrokerApplication -InputObject $app -AdminAddress $adminServer
                Write-Host "$name unpublished"
            }
        }

        return $ret
    }
}

function DoWork() {
    # check if proper version
    if($PSVersionTable.PSVersion.Major -lt 4) {
        Write-Error "This script requires Powershell 4.0 or greater"
        return -1
    }

    # get app servers in delivery group
    Write-Host "Searching for application servers in the delivery group..."
    $appServers = Get-AppServers $deliveryGroup $adminServer
    if($appServers -eq $null ) {
        Write-Error "`nUnable to find application servers for the specified delivery group"
        return -1
    }
    
    foreach ($appServer in $appServers) {

        # install the client if necessary
        Write-Host "Checking if Turbo client is installed..."
        $turbo = InstallTurboIf $appServer.DNSName
        if(-not $turbo) {
            Write-Error "Client must be installed to continue"
            return -1
        }

        # login if necessary
        Write-Host "Login to Turbo..."
        if(-not $(LoginIf $user $password $apiKey $allUsers $turbo $appServer.DNSName)) {
            Write-Error "Must be logged in to continue"
            return -1
        }
   
        # subscribe
        $events = Subscribe $channel $unsubscribe $cacheApps $turbo $appServer.DNSName
        if($events -eq $null ) {
            Write-Error "`nSubscription failed"
            return -1
        }
    
        # publish to citrix
        Write-Host "Publish changes to Citrix..."
        if(-not $(UpdateDeliveryGroup $deliveryGroup $events.InstalledApps $events.UninstalledApps $adminServer)) {
            Write-Error "`nDelivery group update failed"
            return -1
        }
    }
    
    Write-Host "`nDeployment successful"

    return 0
}

$exitCode = DoWork

if($waitOnExit.IsPresent -and $host.Name -notmatch "ise") { # ReadKey not supported in the ISE by design
    Write-Host "Press any key to continue"
    $ret = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

Exit $exitCode
