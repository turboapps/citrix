# Licensed under the Apache License, Version 2.0
# http://www.apache.org/licenses/LICENSE-2.0

<#

.SYNOPSIS

Subscribes a XenApp server to the specified channel and adds the applications.

.DESCRIPTION

This cmdlet will automatically download and install the Turbo client if it isn't already installed for all users. This operation will require the script to be run as a system admin. 

Can install the client manually by downloading from http://start.turbo.net/install and running "turbo-plugin.exe --all-users --silent" as admin.

Requires Powershell 3.0+. Requires XenApp 6.5. Requires Turbo.net Client 3.33.935+.

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

.PARAMETER apiKey

The Turbo.net api key.

.PARAMETER cacheApps

The applications in the channel are to be cached locally. This could be a long operation.

.PARAMETER skipPublish

The applications in the channel are not to be published to the XenApp server.

.PARAMETER waitOnExit

Waits for user confirmation after execution completes

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
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The Turbo.net api key")]
    [string] $apiKey,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The applications in the channel are to be cached locally")]
    [switch] $cacheApps,
    [Parameter(Mandatory=$False,ValueFromPipeline=$False,ValueFromPipelineByPropertyName=$False,HelpMessage="The applications in the channel are not to be published to the XenApp server")]
    [switch] $skipPublish,
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
            $ret = Start-Process -FilePath $turboInstaller -ArgumentList "--all-users", "--silent" -Wait -PassThru
            if($LASTEXITCODE -ne 0) {
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


function LoginIf([string]$user, [string]$password, [string]$apikey, [string]$turbo, [string]$server = "") {
    
    if($server) {
        # send off to the server to perform
        Invoke-Command -ComputerName $server `
            -ArgumentList $user, $password, $apikey, $turbo `
            -ScriptBlock ${function:LoginIf}
    }
    else {
        # use the api key if we have it
        if($apikey) {
            $ret = & $turbo login --api-key=$apikey
            if($LASTEXITCODE -ne 0) {
                Write-Error "Invalid api key"
                return $false
            }
        }
        else {        
            # check if we're logged in (and as the correct user if necessary)
            $login = & $turbo login --format=json | ConvertFrom-Json

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
                $login = & $turbo login --format=json $user $password | ConvertFrom-Json
                if($LASTEXITCODE -eq 0) {
                    $success = $true
                }
                $password = ""
            }
        }

        return $true
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
        if($LASTEXITCODE -ne 0) {
            $events | where { $_.event -and $_.event -eq "error" } | foreach { Write-Host $_.message }
            return $false
        }

        $installEvents = $events | where { $_.event -and $_.event -eq "install" }
        
        # show which apps were subscribe to
        foreach ($event in $installEvents) {
            $name = $event.name
            Write-Host "$name subscribed"
        }
    
        # publish apps
        $ret = $true
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
                        Write-Host "$xaName published"
                    }
                    else {
                        Write-Host "$xaName was not published"
                        $ret = $false
                    }
                }
            }
        }

        # pre-cache apps if necessary
        if($cacheApps) {
            $r = & $turbo subscription update $subscription
            if($LASTEXITCODE -ne 0) {
                Write-Host "Error while caching the subscription"
                $ret = $false
            }
        }

        return $ret
    }
}

function DoWork() {
    # check if proper version
    if($PSVersionTable.PSVersion.Major -lt 3) {
        Write-Error "This script requires Powershell 3.0 or greater"
        return -1
    }

    # install the client if necessary
    Write-Host "Checking if Turbo client is installed..."
    $turbo = InstallTurboIf $server
    if(-not $turbo) {
        Write-Error "Client must be installed to continue"
        return -1
    }

    Write-Host "Subscribe to $channel..."

    # login if necessary
    if(-not $(LoginIf $user $password $apiKey $turbo $server)) {
        Write-Error "Must be logged in to continue"
        return -1
    }
   
    # subscribe
    if(-not $(Subscribe $channel $users $cacheApps.IsPresent $skipPublish.IsPresent $turbo $server)) {
        Write-Error "Deployment failed"
        return -1
    }
    
    Write-Host "Deployment successful"
    return 0
}

# set the server to the local machine if not specified
# this will make the script use remoting even for a local machine but this is necessary to escape the container isolation for client installs
if(-not $server) {
    $server = "127.0.0.1"
}

$exitCode = DoWork

if($waitOnExit.IsPresent -and $host.Name -notmatch "ise") { # ReadKey not supported in the ISE by design
    Write-Host "Press any key to continue"
    $ret = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

Exit $exitCode
