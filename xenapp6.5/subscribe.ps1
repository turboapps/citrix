# Licensed under the Apache License, Version 2.0
# http://www.apache.org/licenses/LICENSE-2.0

<#

.SYNOPSIS

Subscribes a XenApp server to the specified channel and adds the applications.

.DESCRIPTION

This cmdlet will automatically download and install the Turbo client if it isn't already installed for all users. This operation will require the script to be run as a system admin. 

Can install the client manually by downloading from http://start.turbo.net/install and running "turbo-plugin.exe --all-users --silent" as admin.

Requires XenApp 6.5. Requires Turbo.net Client 3.33.935+.

.PARAMETER channel

The name of the channel to subscribe to.

.PARAMETER users

A list of users to give access to the applications. If left empty, the applications will be disabled by default.

.PARAMETER server

The name of a remote XenApp server.

.PARAMETER user

The Turbo.net user with access to the channel. If not specified then will be prompted if necessary.

.PARAMETER password

The password for the Turbo.net user. If not specified then will be prompted if necessary.

.PARAMETER cacheApps

The applications in the channel are to be cached locally. This could be a long operation.

.PARAMETER skipPublish

The applications in the channel are not to be published to the XenApp server.

#>


[CmdletBinding()]
param
(
    [Parameter(Mandatory=$True,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The name of the channel to subscribe to")]
    [string] $channel,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="A list of users to give access to the applications")]
    [string[]] $users,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The name of a remote XenApp server")]
    [string] $server,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The Turbo.net user with access to the channel")]
    [string] $user,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The password for the Turbo.net user")]
    [string] $password,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The applications in the channel are to be cached locally")]
    [switch] $cacheApps,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The applications in the channel are not to be published to the XenApp server")]
    [switch] $skipPublish
)

# returns the path to turbo.exe or empty string if the client is not installed
function InstallTurboIf([string]$server = "") {
    if($server) {
        Invoke-Command -ComputerName $server -ScriptBlock ${function:InstallTurboIf}
    }
    else {
        # check if the client is installed for all users
        $relPath = "spoon\cmd\turbo.exe"
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
            & $turboInstaller --all-users --silent

            # wait for process to complete (Start-Process didn't return with -wait after the installer process exited for some reason)
            $ret = (split-path $turboInstaller -Leaf) -match "(.*)\.([^.]*)" # get the filename w/o extension
            $exe = $matches[1]
            $proc = 1
            while($proc) { # loop until the installer is no longer running
                Start-Sleep -s 2
                $proc = Get-Process $exe -ErrorAction SilentlyContinue | Select-Object name
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


function LoginIf([string]$user, [string]$password, [string]$turbo, [string]$server = "") {
    
    if($server) {
        # send off to the server to perform
        Invoke-Command -ComputerName $server `
            -ArgumentList $user, $password, $turbo `
            -ScriptBlock ${function:LoginIf}
    }
    else {
        # check if we're logged in (and as the correct user if necessary)
        $login = & $turbo login --format=json | ConvertFrom-Json

        if($login.result.exitCode -eq 0 -and $user -and $login.result.user.login -ne $user) {
            # wrong user so re-login
            $login.result.exitCode = -1
        }

        # loop until we have successful login
        while($login.result.exitCode -ne 0)
        {
            if(-not $password) {
                $cred = Get-Credential -UserName $user -Message "Enter your Turbo.net password"
                if(-not $cred) {
                    $false
                    return
                }
                $user = $cred.UserName
                $password = $cred.GetNetworkCredential().Password
            }
            $login = & $turbo login --format=json $user $password | ConvertFrom-Json
            $password = ""
        }

        $true
    }
}

function Subscribe(
    [string]$subscription, 
    [string[]]$users, 
    [bool]$cacheApps, 
    [bool]$skipPublish, 
    [string]$turbo, 
    [string]$server = "") {
    
    if($server) {
        Invoke-Command -ComputerName $server `
            -ArgumentList $subscription, $users, $cacheApps, $skipPublish, $turbo `
            -ScriptBlock ${function:Subscribe}
    }
    else {
        # subscribe to the channel
        $events = & $turbo subscribe $subscription --all-users --format=rpc | ConvertFrom-Json
        $installEvents = $events | where { $_.event -and $_.event -eq "install" }
        if(-not $installEvents) {
            $events | where { $_.event -and $_.event -eq "error" } | foreach { Write-Output $_.message }
            return
        }
        
        # show which apps were subscribe to
        foreach ($event in $installEvents) {
            $name = $event.name
            Write-Output "$name subscribed"
        }
    
        # publish apps
        if(-not $skipPublish) {
            Add-PSSnapin Citrix* -ErrorAction SilentlyContinue # may already be loaded

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

                # check if the app is already here
                $app = Get-XAApplication -BrowserName $xaName -ErrorAction SilentlyContinue
                if(-not $app) {
                    # add the app
                    $ctxIcon = Get-CtxIcon $icon[0] -Index $icon[1] 
                    $app = New-XAApplication $xaName `
                        -ApplicationType ServerInstalled `
                        -CommandLineExecutable "`"$target`" $params" `
                        -ServerNames ($env:COMPUTERNAME) `
                        -Accounts $users `
                        -EncodedIconData $ctxIcon.EncodedIconData 

                    if($app) {
                        Write-Output "$xaName published"
                    }
                }
            }
        }

        # pre-cache apps if necessary
        if($cacheApps) {
            & $turbo subscription update $subscription
        }
    }
}

# install the client if necessary
Write-Output "Checking if Turbo client is installed..."
$turbo = InstallTurboIf $server
if(-not $turbo) {
    Write-Error "Client must be installed to continue"
    exit -1;
}

Write-Output "Subscribe to $channel..."

# login if necessary
if(-not $(LoginIf $user $password $turbo $server)) {
    Write-Error "Must be logged in to continue"
    exit -1
}
   
# subscribe
Subscribe $channel $users $cacheApps.IsPresent $skipPublish.IsPresent $turbo $server

Write-Output "Subscription complete"

