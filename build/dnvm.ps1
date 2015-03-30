#Requires -Version 3

$ScriptPath = $MyInvocation.MyCommand.Definition

$Script:UseWriteHost = $true
function _WriteDebug($msg) {
    if($Script:UseWriteHost) {
        try {
            Write-Debug $msg
        } catch {
            $Script:UseWriteHost = $false
            _WriteDebug $msg
        }
    }
}

function _WriteOut {
    param(
        [Parameter(Mandatory=$false, Position=0, ValueFromPipeline=$true)][string]$msg,
        [Parameter(Mandatory=$false)][ConsoleColor]$ForegroundColor,
        [Parameter(Mandatory=$false)][ConsoleColor]$BackgroundColor,
        [Parameter(Mandatory=$false)][switch]$NoNewLine)

    if(!$Script:UseWriteHost) {
        if(!$msg) {
            $msg = ""
        }
        if($NoNewLine) {
            [Console]::Write($msg)
        } else {
            [Console]::WriteLine($msg)
        }
    }
    else {
        try {
            if(!$ForegroundColor) {
                $ForegroundColor = $host.UI.RawUI.ForegroundColor
            }
            if(!$BackgroundColor) {
                $BackgroundColor = $host.UI.RawUI.BackgroundColor
            }

            Write-Host $msg -ForegroundColor:$ForegroundColor -BackgroundColor:$BackgroundColor -NoNewLine:$NoNewLine
        } catch {
            $Script:UseWriteHost = $false
            _WriteOut $msg
        }
    }

    if($__TeeTo) {
        $cur = Get-Variable -Name $__TeeTo -ValueOnly -Scope Global -ErrorAction SilentlyContinue
        $val = $cur + "$msg"
        if(!$NoNewLine) {
            $val += [Environment]::NewLine
        }
        Set-Variable -Name $__TeeTo -Value $val -Scope Global -Force
    }
}

### Constants
$ProductVersion="1.0.0"
$BuildVersion="beta4-10351"
$Authors="Microsoft Open Technologies, Inc."

# If the Version hasn't been replaced...
# We can't compare directly with the build version token
# because it'll just get replaced here as well :)
if($BuildVersion.StartsWith("{{")) {
    # We're being run from source code rather than the "compiled" artifact
    $BuildVersion = "HEAD"
}
$FullVersion="$ProductVersion-$BuildVersion"

Set-Variable -Option Constant "CommandName" ([IO.Path]::GetFileNameWithoutExtension($ScriptPath))
Set-Variable -Option Constant "CommandFriendlyName" ".NET Version Manager"
Set-Variable -Option Constant "DefaultUserDirectoryName" ".dnx"
Set-Variable -Option Constant "OldUserDirectoryNames" @(".kre", ".k")
Set-Variable -Option Constant "RuntimePackageName" "dnx"
Set-Variable -Option Constant "DefaultFeed" "https://www.myget.org/F/aspnetrelease/api/v2"
Set-Variable -Option Constant "CrossGenCommand" "k-crossgen"
Set-Variable -Option Constant "CommandPrefix" "dnvm-"
Set-Variable -Option Constant "DefaultArchitecture" "x86"
Set-Variable -Option Constant "DefaultRuntime" "clr"
Set-Variable -Option Constant "AliasExtension" ".txt"

# These are intentionally using "%" syntax. The environment variables are expanded whenever the value is used.
Set-Variable -Option Constant "OldUserHomes" @("%USERPROFILE%\.kre","%USERPROFILE%\.k")
Set-Variable -Option Constant "DefaultUserHome" "%USERPROFILE%\$DefaultUserDirectoryName"
Set-Variable -Option Constant "HomeEnvVar" "DNX_HOME"

Set-Variable -Option Constant "RuntimeShortFriendlyName" "DNX"

Set-Variable -Option Constant "AsciiArt" @"
   ___  _  ___   ____  ___
  / _ \/ |/ / | / /  |/  /
 / // /    /| |/ / /|_/ / 
/____/_/|_/ |___/_/  /_/  
"@

$ExitCodes = @{
    "Success"                   = 0
    "AliasDoesNotExist"         = 1001
    "UnknownCommand"            = 1002
    "InvalidArguments"          = 1003
    "OtherError"                = 1004
    "NoSuchPackage"             = 1005
    "NoRuntimesOnFeed"          = 1006
}

$ColorScheme = $DnvmColors
if(!$ColorScheme) {
    $ColorScheme = @{
        "Banner"=[ConsoleColor]::Cyan
        "RuntimeName"=[ConsoleColor]::Yellow
        "Help_Header"=[ConsoleColor]::Yellow
        "Help_Switch"=[ConsoleColor]::Green
        "Help_Argument"=[ConsoleColor]::Cyan
        "Help_Optional"=[ConsoleColor]::Gray
        "Help_Command"=[ConsoleColor]::DarkYellow
        "Help_Executable"=[ConsoleColor]::DarkYellow
    }
}

Set-Variable -Option Constant "OptionPadding" 20

# Test Control Variables
if($__TeeTo) {
    _WriteDebug "Saving output to '$__TeeTo' variable"
    Set-Variable -Name $__TeeTo -Value "" -Scope Global -Force
}

# Commands that have been deprecated but do still work.
$DeprecatedCommands = @("unalias")

# Load Environment variables
$RuntimeHomes = $env:DNX_HOME
$UserHome = $env:DNX_USER_HOME
$ActiveFeed = $env:DNX_FEED

# Default Exit Code
$Script:ExitCode = $ExitCodes.Success

############################################################
### Below this point, the terms "DNVM", "DNX", etc.      ###
### should never be used. Instead, use the Constants     ###
### defined above                                        ###
############################################################
# An exception to the above: The commands are defined by functions
# named "dnvm-[command name]" so that extension functions can be added

$StartPath = $env:PATH

if($CmdPathFile) {
    if(Test-Path $CmdPathFile) {
        _WriteDebug "Cleaning old CMD PATH file: $CmdPathFile"
        Remove-Item $CmdPathFile -Force
    }
    _WriteDebug "Using CMD PATH file: $CmdPathFile"
}

if(!$ActiveFeed) {
    $ActiveFeed = $DefaultFeed
}

# Determine where runtimes can exist (RuntimeHomes)
if(!$RuntimeHomes) {
    # Set up a default value for the runtime home
    $UnencodedHomes = "%USERPROFILE%\$DefaultUserDirectoryName"
} else {
    $UnencodedHomes = $RuntimeHomes
}

$UnencodedHomes = $UnencodedHomes.Split(";")
$RuntimeHomes = $UnencodedHomes | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) }
$RuntimeDirs = $RuntimeHomes | ForEach-Object { Join-Path $_ "runtimes" }

# Determine the default installation directory (UserHome)
if(!$UserHome) {
    _WriteDebug "Detecting User Home..."
    $pf = $env:ProgramFiles
    if(Test-Path "env:\ProgramFiles(x86)") {
        $pf32 = cat "env:\ProgramFiles(x86)"
    }

    # Canonicalize so we can do StartsWith tests
    if(!$pf.EndsWith("\")) { $pf += "\" }
    if($pf32 -and !$pf32.EndsWith("\")) { $pf32 += "\" }

    $UserHome = $RuntimeHomes | Where-Object {
        # Take the first path that isn't under program files
        !($_.StartsWith($pf) -or $_.StartsWith($pf32))
    } | Select-Object -First 1

    _WriteDebug "Found: $UserHome"
    
    if(!$UserHome) {
        $UserHome = "$env:USERPROFILE\$DefaultUserDirectoryName"
    }
}

_WriteDebug ""
_WriteDebug "=== Running $CommandName ==="
_WriteDebug "Runtime Homes: $RuntimeHomes"
_WriteDebug "User Home: $UserHome"
$AliasesDir = Join-Path $UserHome "alias"
$RuntimesDir = Join-Path $UserHome "runtimes"
$Aliases = $null

### Helper Functions
function GetArch($Architecture, $FallBackArch = $DefaultArchitecture) {
    if(![String]::IsNullOrWhiteSpace($Architecture)) {
        $Architecture
    } elseif($CompatArch) {
        $CompatArch
    } else {
        $FallBackArch
    }
}

function GetRuntime($Runtime) {
    if(![String]::IsNullOrWhiteSpace($Runtime)) {
        $Runtime
    } else {
        $DefaultRuntime
    }
}

function Write-Usage {
    _WriteOut -ForegroundColor $ColorScheme.Banner $AsciiArt
    _WriteOut "$CommandFriendlyName v$FullVersion"
    if(!$Authors.StartsWith("{{")) {
        _WriteOut "By $Authors"
    }
    _WriteOut
    _WriteOut -NoNewLine -ForegroundColor $ColorScheme.Help_Header "usage:"
    _WriteOut -NoNewLine -ForegroundColor $ColorScheme.Help_Executable " $CommandName"
    _WriteOut -NoNewLine -ForegroundColor $ColorScheme.Help_Command " <command>"
    _WriteOut -ForegroundColor $ColorScheme.Help_Argument " [<arguments...>]"
}

function Get-RuntimeAlias {
    if($Aliases -eq $null) {
        _WriteDebug "Scanning for aliases in $AliasesDir"
        if(Test-Path $AliasesDir) {
            $Aliases = @(Get-ChildItem ($UserHome + "\alias\") | Select-Object @{label='Alias';expression={$_.BaseName}}, @{label='Name';expression={Get-Content $_.FullName }})
        } else {
            $Aliases = @()
        }
    }
    $Aliases
}

function IsOnPath {
    param($dir)

    $env:Path.Split(';') -icontains $dir
}

function Get-RuntimeId(
    [Parameter()][string]$Architecture,
    [Parameter()][string]$Runtime) {

    $Architecture = GetArch $Architecture
    $Runtime = GetRuntime $Runtime

    "$RuntimePackageName-$Runtime-win-$Architecture".ToLowerInvariant()
}

function Get-RuntimeName(
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter()][string]$Architecture,
    [Parameter()][string]$Runtime) {

    $aliasPath = Join-Path $AliasesDir "$Version$AliasExtension"

    if(Test-Path $aliasPath) {
        $BaseName = Get-Content $aliasPath

        $Architecture = GetArch $Architecture (Get-PackageArch $BaseName)
        $Runtime = GetRuntime $Runtime (Get-PackageArch $BaseName)
        $Version = Get-PackageVersion $BaseName
    }
    
    "$(Get-RuntimeId $Architecture $Runtime).$Version"
}

filter List-Parts {
    param($aliases)

    $binDir = Join-Path $_.FullName "bin"
    if (!(Test-Path $binDir)) {
        return
    }
    $active = IsOnPath $binDir
    
    $fullAlias=""
    $delim=""

    foreach($alias in $aliases) {
        if($_.Name.Split('\', 2) -contains $alias.Name) {
            $fullAlias += $delim + $alias.Alias
            $delim = ", "
        }
    }

    $parts1 = $_.Name.Split('.', 2)
    $parts2 = $parts1[0].Split('-', 4)
    return New-Object PSObject -Property @{
        Active = $active
        Version = $parts1[1]
        Runtime = $parts2[1]
        OperatingSystem = $parts2[2]
        Architecture = $parts2[3]
        Location = $_.Parent.FullName
        Alias = $fullAlias
    }
}

function Read-Alias($Name) {
    _WriteDebug "Listing aliases matching '$Name'"

    $aliases = Get-RuntimeAlias

    $result = @($aliases | Where-Object { !$Name -or ($_.Alias.Contains($Name)) })
    if($Name -and ($result.Length -eq 1)) {
        _WriteOut "Alias '$Name' is set to '$($result[0].Name)'"
    } elseif($Name -and ($result.Length -eq 0)) {
        _WriteOut "Alias does not exist: '$Name'"
        $Script:ExitCode = $ExitCodes.AliasDoesNotExist
    } else {
        $result
    }
}

function Write-Alias {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Version,
        [Parameter(Mandatory=$false)][string]$Architecture,
        [Parameter(Mandatory=$false)][string]$Runtime)

    # If the first character is non-numeric, it's a full runtime name
    if(![Char]::IsDigit($Version[0])) {
        $runtimeFullName = $Version
    } else {
        $runtimeFullName = Get-RuntimeName $Version $Architecture $Runtime
    }
    $aliasFilePath = Join-Path $AliasesDir "$Name.txt"
    $action = if (Test-Path $aliasFilePath) { "Updating" } else { "Setting" }
    
    if(!(Test-Path $AliasesDir)) {
        _WriteDebug "Creating alias directory: $AliasesDir"
        New-Item -Type Directory $AliasesDir | Out-Null
    }
    _WriteOut "$action alias '$Name' to '$runtimeFullName'"
    $runtimeFullName | Out-File $aliasFilePath ascii
}

function Delete-Alias {
    param(
        [Parameter(Mandatory=$true)][string]$Name)

    $aliasPath = Join-Path $AliasesDir "$Name.txt"
    if (Test-Path -literalPath "$aliasPath") {
        _WriteOut "Removing alias $Name"

        # Delete with "-Force" because we already confirmed above
        Remove-Item -literalPath $aliasPath -Force
    } else {
        _WriteOut "Cannot remove alias '$Name'. It does not exist."
        $Script:ExitCode = $ExitCodes.AliasDoesNotExist # Return non-zero exit code for scripting
    }
}

function Apply-Proxy {
param(
  [System.Net.WebClient] $wc,
  [string]$Proxy
)
  if (!$Proxy) {
    $Proxy = $env:http_proxy
  }
  if ($Proxy) {
    $wp = New-Object System.Net.WebProxy($Proxy)
    $pb = New-Object UriBuilder($Proxy)
    if (!$pb.UserName) {
        $wp.Credentials = [System.Net.CredentialCache]::DefaultCredentials
    } else {
        $wp.Credentials = New-Object System.Net.NetworkCredential($pb.UserName, $pb.Password)
    }
    $wc.Proxy = $wp
  }
}

function Find-Latest {
    param(
        [string]$runtime = "",
        [string]$architecture = "",
        [string]$Feed,
        [string]$Proxy
    )
    if(!$Feed) { $Feed = $ActiveFeed }

    _WriteOut "Determining latest version"

    $RuntimeId = Get-RuntimeId -Architecture:"$architecture" -Runtime:"$runtime"
    $url = "$Feed/GetUpdates()?packageIds=%27$RuntimeId%27&versions=%270.0%27&includePrerelease=true&includeAllVersions=false"

    # NOTE: DO NOT use Invoke-WebRequest. It requires PowerShell 4.0!

    $wc = New-Object System.Net.WebClient
    Apply-Proxy $wc -Proxy:$Proxy
    _WriteDebug "Downloading $url ..."
    try {
        [xml]$xml = $wc.DownloadString($url)
    } catch {
        $Script:ExitCode = $ExitCodes.NoRuntimesOnFeed
        throw "Unable to find any runtime packages on the feed!"
    }

    $version = Select-Xml "//d:Version" -Namespace @{d='http://schemas.microsoft.com/ado/2007/08/dataservices'} $xml

    if (![String]::IsNullOrWhiteSpace($version)) {
        _WriteDebug "Found latest version: $version"
        $version
    }
}

function Get-PackageVersion() {
    param(
        [string] $runtimeFullName
    )
    return $runtimeFullName -replace '[^.]*.(.*)', '$1'
}

function Get-PackageRuntime() {
    param(
        [string] $runtimeFullName
    )
    return $runtimeFullName -replace "$RuntimePackageName-([^-]*).*", '$1'
}

function Get-PackageArch() {
    param(
        [string] $runtimeFullName
    )
    return $runtimeFullName -replace "$RuntimePackageName-[^-]*-[^-]*-([^.]*).*", '$1'
}

function Download-Package(
    [string]$Version,
    [string]$Architecture,
    [string]$Runtime,
    [string]$DestinationFile,
    [string]$Feed,
    [string]$Proxy) {

    if(!$Feed) { $Feed = $ActiveFeed }
    
    $url = "$Feed/package/" + (Get-RuntimeId $Architecture $Runtime) + "/" + $Version
    
    _WriteOut "Downloading $runtimeFullName from $feed"
    $wc = New-Object System.Net.WebClient
    try {
      Apply-Proxy $wc -Proxy:$Proxy     
      _WriteDebug "Downloading $url ..."

      Register-ObjectEvent $wc DownloadProgressChanged -SourceIdentifier WebClient.ProgressChanged -action {
        $Global:downloadData = $eventArgs
      } | Out-Null

      Register-ObjectEvent $wc DownloadFileCompleted -SourceIdentifier WebClient.ProgressComplete -action {
        $Global:downloadData = $eventArgs
        $Global:downloadCompleted = $true
      } | Out-Null

      $wc.DownloadFileAsync($url, $DestinationFile)

      while(-not $Global:downloadCompleted){
        $percent = $Global:downloadData.ProgressPercentage
        $totalBytes = $Global:downloadData.TotalBytesToReceive
        $receivedBytes = $Global:downloadData.BytesReceived
        If ($percent -ne $null) {
            Write-Progress -Activity ("Downloading $RuntimeShortFriendlyName from $url") `
                -Status ("Downloaded $($Global:downloadData.BytesReceived) of $($Global:downloadData.TotalBytesToReceive) bytes") `
                -PercentComplete $percent -Id 2 -ParentId 1
        }
      }

      if($Global:downloadData.Error){
        throw "Unable to download package: {0}" -f $Global:downloadData.Error.Message
      }

      Write-Progress -Activity ("Downloading $RuntimeShortFriendlyName from $url") -Id 2 -ParentId 1 -Completed
    }
    finally {
        Remove-Variable downloadData -Scope "Global"
        Remove-Variable downloadCompleted -Scope "Global"
        Unregister-Event -SourceIdentifier WebClient.ProgressChanged
        Unregister-Event -SourceIdentifier WebClient.ProgressComplete
        $wc.Dispose()
    }
}

function Unpack-Package([string]$DownloadFile, [string]$UnpackFolder) {
    _WriteDebug "Unpacking $DownloadFile to $UnpackFolder"

    $compressionLib = [System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem')

    if($compressionLib -eq $null) {
      try {
          # Shell will not recognize nupkg as a zip and throw, so rename it to zip
          $runtimeZip = [System.IO.Path]::ChangeExtension($DownloadFile, "zip")
          Rename-Item $DownloadFile $runtimeZip
          # Use the shell to uncompress the nupkg
          $shell_app=new-object -com shell.application
          $zip_file = $shell_app.namespace($runtimeZip)
          $destination = $shell_app.namespace($UnpackFolder)
          $destination.Copyhere($zip_file.items(), 0x14) #0x4 = don't show UI, 0x10 = overwrite files
      }
      finally {
        # Clean up the package file itself.
        Remove-Item $runtimeZip -Force
      }
    } else {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($DownloadFile, $UnpackFolder)
        
        # Clean up the package file itself.
        Remove-Item $DownloadFile -Force
    }

    If (Test-Path -LiteralPath ($UnpackFolder + "\[Content_Types].xml")) {
        Remove-Item -LiteralPath ($UnpackFolder + "\[Content_Types].xml")
    }
    If (Test-Path ($UnpackFolder + "\_rels\")) {
        Remove-Item -LiteralPath ($UnpackFolder + "\_rels\") -Force -Recurse
    }
    If (Test-Path ($UnpackFolder + "\package\")) {
        Remove-Item -LiteralPath ($UnpackFolder + "\package\") -Force -Recurse
    }
}

function Get-RuntimePath($runtimeFullName) {
    _WriteDebug "Resolving $runtimeFullName"
    foreach($RuntimeHome in $RuntimeHomes) {
        $runtimeBin = "$RuntimeHome\runtimes\$runtimeFullName\bin"
        _WriteDebug " Candidate $runtimeBin"
        if (Test-Path "$runtimeBin") {
            _WriteDebug " Found in $runtimeBin"
            return $runtimeBin
        }
    }
    return $null
}

function Change-Path() {
    param(
        [string] $existingPaths,
        [string] $prependPath,
        [string[]] $removePaths
    )
    _WriteDebug "Updating value to prepend '$prependPath' and remove '$removePaths'"
    
    $newPath = $prependPath
    foreach($portion in $existingPaths.Split(';')) {
        if(![string]::IsNullOrWhiteSpace($portion)) {
            $skip = $portion -eq ""
            foreach($removePath in $removePaths) {
                if(![string]::IsNullOrWhiteSpace($removePath)) {
                    $removePrefix = if($removePath.EndsWith("\")) { $removePath } else { "$removePath\" }

                    if ($removePath -and (($portion -eq $removePath) -or ($portion.StartsWith($removePrefix)))) {
                        _WriteDebug " Removing '$portion' because it matches '$removePath'"
                        $skip = $true
                    }
                }
            }
            if (!$skip) {
                if(![String]::IsNullOrWhiteSpace($newPath)) {
                    $newPath += ";"
                }
                $newPath += $portion
            }
        }
    }
    return $newPath
}

function Set-Path() {
    param(
        [string] $newPath
    )

    $env:PATH = $newPath

    if($CmdPathFile) {
        $Parent = Split-Path -Parent $CmdPathFile
        if(!(Test-Path $Parent)) {
            New-Item -Type Directory $Parent -Force | Out-Null
        }
        _WriteDebug " Writing PATH file for CMD script"
        @"
SET "PATH=$newPath"
"@ | Out-File $CmdPathFile ascii
    }
}

function Ngen-Library(
    [Parameter(Mandatory=$true)]
    [string]$runtimeBin,

    [ValidateSet("x86","x64")]
    [Parameter(Mandatory=$true)]
    [string]$architecture) {

    if ($architecture -eq 'x64') {
        $regView = [Microsoft.Win32.RegistryView]::Registry64
    }
    elseif ($architecture -eq 'x86') {
        $regView = [Microsoft.Win32.RegistryView]::Registry32
    }
    else {
        _WriteOut "Installation does not understand architecture $architecture, skipping ngen..."
        return
    }

    $regHive = [Microsoft.Win32.RegistryHive]::LocalMachine
    $regKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($regHive, $regView)
    $frameworkPath = $regKey.OpenSubKey("SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full").GetValue("InstallPath")
    $ngenExe = Join-Path $frameworkPath 'ngen.exe'

    $ngenCmds = ""
    foreach ($bin in Get-ChildItem $runtimeBin -Filter "Microsoft.CodeAnalysis.CSharp.dll") {
        $ngenCmds += "$ngenExe install $($bin.FullName);"
    }

    $ngenProc = Start-Process "$psHome\powershell.exe" -Verb runAs -ArgumentList "-ExecutionPolicy unrestricted & $ngenCmds" -Wait -PassThru -WindowStyle Hidden
}

function Is-Elevated() {
    $user = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $user.IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
}

### Commands

<#
.SYNOPSIS
    Displays a list of commands, and help for specific commands
.PARAMETER Command
    A specific command to get help for
#>
function dnvm-help {
    [CmdletBinding(DefaultParameterSetName="GeneralHelp")]
    param(
        [Parameter(Mandatory=$true,Position=0,ParameterSetName="SpecificCommand")][string]$Command,
        [switch]$PassThru)

    if($Command) {
        $cmd = Get-Command "dnvm-$Command" -ErrorAction SilentlyContinue
        if(!$cmd) {
            _WriteOut "No such command: $Command"
            dnvm-help
            $Script:ExitCodes = $ExitCodes.UnknownCommand
            return
        }
        $help = Get-Help "dnvm-$Command"
        if($PassThru) {
            $help
        } else {
            _WriteOut -ForegroundColor $ColorScheme.Help_Header "$CommandName-$Command"
            _WriteOut "  $($help.Synopsis.Trim())"
            _WriteOut
            _WriteOut -ForegroundColor $ColorScheme.Help_Header "usage:"
            $help.Syntax.syntaxItem | ForEach-Object {
                _WriteOut -NoNewLine -ForegroundColor $ColorScheme.Help_Executable "  $CommandName "
                _WriteOut -NoNewLine -ForegroundColor $ColorScheme.Help_Command "$Command"
                if($_.parameter) {
                    $_.parameter | ForEach-Object {
                        $cmdParam = $cmd.Parameters[$_.name]
                        $name = $_.name
                        if($cmdParam.Aliases.Length -gt 0) {
                            $name = $cmdParam.Aliases | Sort-Object | Select-Object -First 1
                        }

                        _WriteOut -NoNewLine " "
                        
                        if($_.required -ne "true") {
                            _WriteOut -NoNewLine -ForegroundColor $ColorScheme.Help_Optional "["
                        }

                        if($_.position -eq "Named") {
                            _WriteOut -NoNewLine -ForegroundColor $ColorScheme.Help_Switch "-$name"
                        }
                        if($_.parameterValue) {
                            if($_.position -eq "Named") {
                                _WriteOut -NoNewLine " "       
                            }
                            _WriteOut -NoNewLine -ForegroundColor $ColorScheme.Help_Argument "<$($_.name)>"
                        }

                        if($_.required -ne "true") {
                            _WriteOut -NoNewLine -ForegroundColor $ColorScheme.Help_Optional "]"
                        }
                    }
                }
                _WriteOut
            }

            if($help.parameters -and $help.parameters.parameter) {
                _WriteOut
                _WriteOut -ForegroundColor $ColorScheme.Help_Header "options:"
                $help.parameters.parameter | ForEach-Object {
                    $cmdParam = $cmd.Parameters[$_.name]
                    $name = $_.name
                    if($cmdParam.Aliases.Length -gt 0) {
                        $name = $cmdParam.Aliases | Sort-Object | Select-Object -First 1
                    }
                    
                    _WriteOut -NoNewLine "  "
                    
                    if($_.position -eq "Named") {
                        _WriteOut -NoNewLine -ForegroundColor $ColorScheme.Help_Switch "-$name".PadRight($OptionPadding)
                    } else {
                        _WriteOut -NoNewLine -ForegroundColor $ColorScheme.Help_Argument "<$($_.name)>".PadRight($OptionPadding)
                    }
                    _WriteOut " $($_.description.Text)"
                }
            }

            if($help.description) {
                _WriteOut
                _WriteOut -ForegroundColor $ColorScheme.Help_Header "remarks:"
                $help.description.Text.Split(@("`r","`n"), "RemoveEmptyEntries") | 
                    ForEach-Object { _WriteOut "  $_" }
            }

            if($DeprecatedCommands -contains $Command) {
                _WriteOut "This command has been deprecated and should not longer be used"
            }
        }
    } else {
        Write-Usage
        _WriteOut
        _WriteOut -ForegroundColor $ColorScheme.Help_Header "commands: "
        Get-Command "$CommandPrefix*" | 
            ForEach-Object {
                $h = Get-Help $_.Name
                $name = $_.Name.Substring($CommandPrefix.Length)
                if($DeprecatedCommands -notcontains $name) {
                    _WriteOut -NoNewLine "    "
                    _WriteOut -NoNewLine -ForegroundColor $ColorScheme.Help_Command $name.PadRight(10)
                    _WriteOut " $($h.Synopsis.Trim())"
                }
            }
    }
}

<#
.SYNOPSIS
    Lists available runtimes
.PARAMETER PassThru
    Set this switch to return unformatted powershell objects for use in scripting
#>
function dnvm-list {
    param(
        [Parameter(Mandatory=$false)][switch]$PassThru)
    $aliases = Get-RuntimeAlias

    $items = @()
    $RuntimeHomes | ForEach-Object {
        _WriteDebug "Scanning $_ for runtimes..."
        if (Test-Path "$_\runtimes") {
            $items += Get-ChildItem "$_\runtimes\$RuntimePackageName-*" | List-Parts $aliases
        }
    }

    if($PassThru) {
        $items
    } else {
        $items | 
            Sort-Object Version, Runtime, Architecture, Alias | 
            Format-Table -AutoSize -Property @{name="Active";expression={if($_.Active) { "*" } else { "" }};alignment="center"}, "Version", "Runtime", "Architecture", "Location", "Alias"
    }
}

<#
.SYNOPSIS
    Lists and manages aliases
.PARAMETER Name
    The name of the alias to read/create/delete
.PARAMETER Version
    The version to assign to the new alias
.PARAMETER Architecture
    The architecture of the runtime to assign to this alias
.PARAMETER Runtime
    The flavor of the runtime to assign to this alias
.PARAMETER Delete
    Set this switch to delete the alias with the specified name
.DESCRIPTION
    If no arguments are provided, this command lists all aliases. If <Name> is provided,
    the value of that alias, if present, is displayed. If <Name> and <Version> are
    provided, the alias <Name> is set to the runtime defined by <Version>, <Architecture>
    (defaults to 'x86') and <Runtime> (defaults to 'clr').

    Finally, if the '-d' switch is provided, the alias <Name> is deleted, if it exists.
#>
function dnvm-alias {
    param(
        [Alias("d")]
        [Parameter(ParameterSetName="Delete",Mandatory=$true)]
        [switch]$Delete,

        [Parameter(ParameterSetName="Read",Mandatory=$false,Position=0)]
        [Parameter(ParameterSetName="Write",Mandatory=$true,Position=0)]
        [Parameter(ParameterSetName="Delete",Mandatory=$true,Position=0)]
        [string]$Name,
        
        [Parameter(ParameterSetName="Write",Mandatory=$true,Position=1)]
        [string]$Version,

        [Alias("arch")]
        [ValidateSet("", "x86","x64")]
        [Parameter(ParameterSetName="Write", Mandatory=$false)]
        [string]$Architecture = "",

        [Alias("r")]
        [ValidateSet("", "clr","coreclr")]
        [Parameter(ParameterSetName="Write")]
        [string]$Runtime = "")

    switch($PSCmdlet.ParameterSetName) {
        "Read" { Read-Alias $Name }
        "Write" { Write-Alias $Name $Version -Architecture $Architecture -Runtime $Runtime }
        "Delete" { Delete-Alias $Name }
    }
}

<#
.SYNOPSIS
    [DEPRECATED] Removes an alias
.PARAMETER Name
    The name of the alias to remove
#>
function dnvm-unalias {
    param(
        [Parameter(Mandatory=$true,Position=0)][string]$Name)
    _WriteOut "This command has been deprecated. Use '$CommandName alias -d' instead"
    dnvm-alias -Delete -Name $Name
}

<#
.SYNOPSIS
    Installs the latest version of the runtime and reassigns the specified alias to point at it
.PARAMETER Alias
    The alias to upgrade (default: 'default')
.PARAMETER Architecture
    The processor architecture of the runtime to install (default: x86)
.PARAMETER Runtime
    The runtime flavor to install (default: clr)
.PARAMETER Force
    Overwrite an existing runtime if it already exists
.PARAMETER Proxy
    Use the given address as a proxy when accessing remote server
.PARAMETER NoNative
    Skip generation of native images
.PARAMETER Ngen
    For CLR flavor only. Generate native images for runtime libraries on Desktop CLR to improve startup time. This option requires elevated privilege and will be automatically turned on if the script is running in administrative mode. To opt-out in administrative mode, use -NoNative switch.
#>
function dnvm-upgrade {
    param(
        [Alias("a")]
        [Parameter(Mandatory=$false, Position=0)]
        [string]$Alias = "default",

        [Alias("arch")]
        [ValidateSet("", "x86","x64")]
        [Parameter(Mandatory=$false)]
        [string]$Architecture = "",

        [Alias("r")]
        [ValidateSet("", "clr","coreclr")]
        [Parameter(Mandatory=$false)]
        [string]$Runtime = "",

        [Alias("f")]
        [Parameter(Mandatory=$false)]
        [switch]$Force,

        [Parameter(Mandatory=$false)]
        [string]$Proxy,

        [Parameter(Mandatory=$false)]
        [switch]$NoNative,

        [Parameter(Mandatory=$false)]
        [switch]$Ngen)

    dnvm-install "latest" -Alias:$Alias -Architecture:$Architecture -Runtime:$Runtime -Force:$Force -Proxy:$Proxy -NoNative:$NoNative -Ngen:$Ngen -Persistent:$true
}

<#
.SYNOPSIS
    Installs a version of the runtime
.PARAMETER VersionNuPkgOrAlias
    The version to install from the current channel, the path to a '.nupkg' file to install, 'latest' to
    install the latest available version from the current channel, or an alias value to install an alternate
    runtime or architecture flavor of the specified alias.
.PARAMETER Architecture
    The processor architecture of the runtime to install (default: x86)
.PARAMETER Runtime
    The runtime flavor to install (default: clr)
.PARAMETER Alias
    Set alias <Alias> to the installed runtime
.PARAMETER Force
    Overwrite an existing runtime if it already exists
.PARAMETER Proxy
    Use the given address as a proxy when accessing remote server
.PARAMETER NoNative
    Skip generation of native images
.PARAMETER Ngen
    For CLR flavor only. Generate native images for runtime libraries on Desktop CLR to improve startup time. This option requires elevated privilege and will be automatically turned on if the script is running in administrative mode. To opt-out in administrative mode, use -NoNative switch.
.PARAMETER Persistent
    Make the installed runtime useable across all processes run by the current user
.DESCRIPTION
    A proxy can also be specified by using the 'http_proxy' environment variable

#>
function dnvm-install {
    param(
        [Parameter(Mandatory=$false, Position=0)]
        [string]$VersionNuPkgOrAlias,

        [Alias("arch")]
        [ValidateSet("", "x86","x64")]
        [Parameter(Mandatory=$false)]
        [string]$Architecture = "",

        [Alias("r")]
        [ValidateSet("", "clr","coreclr")]
        [Parameter(Mandatory=$false)]
        [string]$Runtime = "",

        [Alias("a")]
        [Parameter(Mandatory=$false)]
        [string]$Alias,

        [Alias("f")]
        [Parameter(Mandatory=$false)]
        [switch]$Force,

        [Parameter(Mandatory=$false)]
        [string]$Proxy,

        [Parameter(Mandatory=$false)]
        [switch]$NoNative,

        [Parameter(Mandatory=$false)]
        [switch]$Ngen,

        [Parameter(Mandatory=$false)]
        [switch]$Persistent)

    if(!$VersionNuPkgOrAlias) {
        _WriteOut "A version, nupkg path, or the string 'latest' must be provided."
        dnvm-help install
        $Script:ExitCode = $ExitCodes.InvalidArguments
        return
    }

    if ($VersionNuPkgOrAlias -eq "latest") {
        Write-Progress -Activity "Installing runtime" "Determining latest runtime" -Id 1
        $VersionNuPkgOrAlias = Find-Latest $Runtime $Architecture
    }

    $IsNuPkg = $VersionNuPkgOrAlias.EndsWith(".nupkg")

    if ($IsNuPkg) {
        if(!(Test-Path $VersionNuPkgOrAlias)) {
            throw "Unable to locate package file: '$VersionNuPkgOrAlias'"
        }
        Write-Progress -Activity "Installing runtime" "Parsing package file name" -Id 1
        $runtimeFullName = [System.IO.Path]::GetFileNameWithoutExtension($VersionNuPkgOrAlias)
        $Architecture = Get-PackageArch $runtimeFullName
        $Runtime = Get-PackageRuntime $runtimeFullName
    } else {
        $runtimeFullName = Get-RuntimeName $VersionNuPkgOrAlias -Architecture:$Architecture -Runtime:$Runtime
    }

    $PackageVersion = Get-PackageVersion $runtimeFullName
    
    _WriteDebug "Preparing to install runtime '$runtimeFullName'"
    _WriteDebug "Architecture: $Architecture"
    _WriteDebug "Runtime: $Runtime"
    _WriteDebug "Version: $PackageVersion"

    $RuntimeFolder = Join-Path $RuntimesDir $runtimeFullName
    _WriteDebug "Destination: $RuntimeFolder"

    if((Test-Path $RuntimeFolder) -and $Force) {
        _WriteOut "Cleaning existing installation..."
        Remove-Item $RuntimeFolder -Recurse -Force
    }

    if(Test-Path $RuntimeFolder) {
        _WriteOut "'$runtimeFullName' is already installed."
    }
    else {
        $Architecture = GetArch $Architecture
        $Runtime = GetRuntime $Runtime
        $UnpackFolder = Join-Path $RuntimesDir "temp"
        $DownloadFile = Join-Path $UnpackFolder "$runtimeFullName.nupkg"

        if(Test-Path $UnpackFolder) {
            _WriteDebug "Cleaning temporary directory $UnpackFolder"
            Remove-Item $UnpackFolder -Recurse -Force
        }
        New-Item -Type Directory $UnpackFolder | Out-Null

        if($IsNuPkg) {
            Write-Progress -Activity "Installing runtime" "Copying package" -Id 1
            _WriteDebug "Copying local nupkg $VersionNuPkgOrAlias to $DownloadFile"
            Copy-Item $VersionNuPkgOrAlias $DownloadFile
        } else {
            # Download the package
            Write-Progress -Activity "Installing runtime" "Downloading runtime" -Id 1
            _WriteDebug "Downloading version $VersionNuPkgOrAlias to $DownloadFile"
            Download-Package $PackageVersion $Architecture $Runtime $DownloadFile -Proxy:$Proxy
        }

        Write-Progress -Activity "Installing runtime" "Unpacking runtime" -Id 1
        Unpack-Package $DownloadFile $UnpackFolder

        New-Item -Type Directory $RuntimeFolder -Force | Out-Null
        _WriteOut "Installing to $RuntimeFolder"
        _WriteDebug "Moving package contents to $RuntimeFolder"
        Move-Item "$UnpackFolder\*" $RuntimeFolder
        _WriteDebug "Cleaning temporary directory $UnpackFolder"
        Remove-Item $UnpackFolder -Force | Out-Null

        dnvm-use $PackageVersion -Architecture:$Architecture -Runtime:$Runtime -Persistent:$Persistent

        if ($Runtime -eq "clr") {
            if (-not $NoNative) {
                if ((Is-Elevated) -or $Ngen) {
                    $runtimeBin = Get-RuntimePath $runtimeFullName
                    Write-Progress -Activity "Installing runtime" "Generating runtime native images" -Id 1
                    Ngen-Library $runtimeBin $Architecture
                }
                else {
                    _WriteOut "Native image generation (ngen) is skipped. Include -Ngen switch to turn on native image generation to improve application startup time."
                }
            }
        }
        elseif ($Runtime -eq "coreclr") {
            if ($NoNative) {
                _WriteOut "Skipping native image compilation."
            }
            else {
                _WriteOut "Compiling native images for $runtimeFullName to improve startup performance..."
                Write-Progress -Activity "Installing runtime" "Generating runtime native images" -Id 1
                if ($DebugPreference -eq 'SilentlyContinue') {
                    Start-Process $CrossGenCommand -Wait -WindowStyle Hidden
                }
                else {
                    Start-Process $CrossGenCommand -Wait -NoNewWindow
                }
                _WriteOut "Finished native image compilation."
            }
        }
        else {
            _WriteOut "Unexpected platform: $Runtime. No optimization would be performed on the package installed."
        }
    }

    if($Alias) {
        _WriteDebug "Aliasing installed runtime to '$Alias'"
        dnvm-alias $Alias $PackageVersion -Architecture:$Architecture -Runtime:$Runtime
    }

    Write-Progress -Activity "Install complete" -Id 1 -Complete
}


<#
.SYNOPSIS
    Adds a runtime to the PATH environment variable for your current shell
.PARAMETER VersionOrAlias
    The version or alias of the runtime to place on the PATH
.PARAMETER Architecture
    The processor architecture of the runtime to place on the PATH (default: x86, or whatever the alias specifies in the case of use-ing an alias)
.PARAMETER Runtime
    The runtime flavor of the runtime to place on the PATH (default: clr, or whatever the alias specifies in the case of use-ing an alias)
.PARAMETER Persistent
    Make the change persistent across all processes run by the current user
#>
function dnvm-use {
    param(
        [Parameter(Mandatory=$false, Position=0)]
        [string]$VersionOrAlias,

        [Alias("arch")]
        [ValidateSet("", "x86","x64")]
        [Parameter(Mandatory=$false)]
        [string]$Architecture = "",

        [Alias("r")]
        [ValidateSet("", "clr","coreclr")]
        [Parameter(Mandatory=$false)]
        [string]$Runtime = "",

        [Alias("p")]
        [Parameter(Mandatory=$false)]
        [switch]$Persistent)

    if([String]::IsNullOrWhiteSpace($VersionOrAlias)) {
        _WriteOut "Missing version or alias to add to path"
        dnvm-help use
        $Script:ExitCode = $ExitCodes.InvalidArguments
        return
    }

    if ($versionOrAlias -eq "none") {
        _WriteOut "Removing all runtimes from process PATH"
        Set-Path (Change-Path $env:Path "" ($RuntimeDirs))

        if ($Persistent) {
            _WriteOut "Removing all runtimes from user PATH"
            $userPath = [Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::User)
            $userPath = Change-Path $userPath "" ($RuntimeDirs)
            [Environment]::SetEnvironmentVariable("Path", $userPath, [System.EnvironmentVariableTarget]::User)
        }
        return;
    }

    $runtimeFullName = Get-RuntimeName $VersionOrAlias $Architecture $Runtime
    $runtimeBin = Get-RuntimePath $runtimeFullName
    if ($runtimeBin -eq $null) {
        throw "Cannot find $runtimeFullName, do you need to run '$CommandName install $versionOrAlias'?"
    }

    _WriteOut "Adding $runtimeBin to process PATH"
    Set-Path (Change-Path $env:Path $runtimeBin ($RuntimeDirs))

    if ($Persistent) {
        _WriteOut "Adding $runtimeBin to user PATH"
        $userPath = [Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::User)
        $userPath = Change-Path $userPath $runtimeBin ($RuntimeDirs)
        [Environment]::SetEnvironmentVariable("Path", $userPath, [System.EnvironmentVariableTarget]::User)
    }
}

<#
.SYNOPSIS
    Gets the full name of a runtime
.PARAMETER VersionOrAlias
    The version or alias of the runtime to place on the PATH
.PARAMETER Architecture
    The processor architecture of the runtime to place on the PATH (default: x86, or whatever the alias specifies in the case of use-ing an alias)
.PARAMETER Runtime
    The runtime flavor of the runtime to place on the PATH (default: clr, or whatever the alias specifies in the case of use-ing an alias)
#>
function dnvm-name {
    param(
        [Parameter(Mandatory=$false, Position=0)]
        [string]$VersionOrAlias,

        [Alias("arch")]
        [ValidateSet("x86","x64")]
        [Parameter(Mandatory=$false)]
        [string]$Architecture = "",

        [Alias("r")]
        [ValidateSet("clr","coreclr")]
        [Parameter(Mandatory=$false)]
        [string]$Runtime = "")

    Get-RuntimeName $VersionOrAlias $Architecture $Runtime
}


# Checks if a specified file exists in the destination folder and if not, copies the file
# to the destination folder. 
function Safe-Filecopy {
    param(
        [Parameter(Mandatory=$true, Position=0)] $Filename, 
        [Parameter(Mandatory=$true, Position=1)] $SourceFolder,
        [Parameter(Mandatory=$true, Position=2)] $DestinationFolder)

    # Make sure the destination folder is created if it doesn't already exist.
    if(!(Test-Path $DestinationFolder)) {
        _WriteOut "Creating destination folder '$DestinationFolder' ... "
        
        New-Item -Type Directory $Destination | Out-Null
    }

    $sourceFilePath = Join-Path $SourceFolder $Filename
    $destFilePath = Join-Path $DestinationFolder $Filename

    if(Test-Path $sourceFilePath) {
        _WriteOut "Installing '$Filename' to '$DestinationFolder' ... "

        if (Test-Path $destFilePath) {
            _WriteOut "  Skipping: file already exists" -ForegroundColor Yellow
        }
        else {
            Copy-Item $sourceFilePath $destFilePath -Force
        }
    }
    else {
        _WriteOut "WARNING: Unable to install: Could not find '$Filename' in '$SourceFolder'. " 
    }
}

<#
.SYNOPSIS
    Installs the version manager into your User profile directory
.PARAMETER SkipUserEnvironmentInstall
    Set this switch to skip configuring the user-level DNX_HOME and PATH environment variables
#>
function dnvm-setup {
    param(
        [switch]$SkipUserEnvironmentInstall)

    $DestinationHome = "$env:USERPROFILE\$DefaultUserDirectoryName"

    # Install scripts
    $Destination = "$DestinationHome\bin"
    _WriteOut "Installing $CommandFriendlyName to $Destination"

    $ScriptFolder = Split-Path -Parent $ScriptPath

    # Copy script files (if necessary):
    Safe-Filecopy "$CommandName.ps1" $ScriptFolder $Destination
    Safe-Filecopy "$CommandName.cmd" $ScriptFolder $Destination

    # Configure Environment Variables
    # Also, clean old user home values if present
    # We'll be removing any existing homes, both
    $PathsToRemove = @(
        "%USERPROFILE%\$DefaultUserDirectoryName",
        [Environment]::ExpandEnvironmentVariables($OldUserHome),
        $DestinationHome,
        $OldUserHome)

    # First: PATH
    _WriteOut "Adding $Destination to Process PATH"
    Set-Path (Change-Path $env:PATH $Destination $PathsToRemove)

    if(!$SkipUserEnvironmentInstall) {
        _WriteOut "Adding $Destination to User PATH"
        $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
        $userPath = Change-Path $userPath $Destination $PathsToRemove
        [Environment]::SetEnvironmentVariable("PATH", $userPath, "User")
    }

    # Now the HomeEnvVar
    _WriteOut "Adding $DestinationHome to Process $HomeEnvVar"
    $processHome = ""
    if(Test-Path "env:\$HomeEnvVar") {
        $processHome = cat "env:\$HomeEnvVar"
    }
    $processHome = Change-Path $processHome "%USERPROFILE%\$DefaultUserDirectoryName" $PathsToRemove
    Set-Content "env:\$HomeEnvVar" $processHome

    if(!$SkipUserEnvironmentInstall) {
        _WriteOut "Adding $DestinationHome to User $HomeEnvVar"
        $userHomeVal = [Environment]::GetEnvironmentVariable($HomeEnvVar, "User")
        $userHomeVal = Change-Path $userHomeVal "%USERPROFILE%\$DefaultUserDirectoryName" $PathsToRemove
        [Environment]::SetEnvironmentVariable($HomeEnvVar, $userHomeVal, "User")
    }
}

### The main "entry point"

# Check for old DNX_HOME values
if($UnencodedHomes -contains $OldUserHome) {
    _WriteOut -ForegroundColor Yellow "WARNING: Found '$OldUserHome' in your $HomeEnvVar value. This folder has been deprecated."
    if($UnencodedHomes -notcontains $DefaultUserHome) {
        _WriteOut -ForegroundColor Yellow "WARNING: Didn't find '$DefaultUserHome' in your $HomeEnvVar value. You should run '$CommandName setup' to upgrade."
    }
}

# Check for old KRE_HOME variable
if(Test-Path env:\KRE_HOME) {
    _WriteOut -ForegroundColor Yellow "WARNING: Found a KRE_HOME environment variable. This variable has been deprecated and should be removed, or it may interfere with DNVM and the .NET Execution environment"
}

# Read arguments

$cmd = $args[0]

if($args.Length -gt 1) {
    $cmdargs = @($args[1..($args.Length-1)])
} else {
    $cmdargs = @()
}

# Can't add this as script-level arguments because they mask '-a' arguments in subcommands!
# So we manually parse them :)
if($cmdargs -icontains "-amd64") {
    $CompatArch = "x64"
    _WriteOut "The -amd64 switch has been deprecated. Use the '-arch x64' parameter instead"
} elseif($cmdargs -icontains "-x86") {
    $CompatArch = "x86"
    _WriteOut "The -x86 switch has been deprecated. Use the '-arch x86' parameter instead"
} elseif($cmdargs -icontains "-x64") {
    $CompatArch = "x64"
    _WriteOut "The -x64 switch has been deprecated. Use the '-arch x64' parameter instead"
}
$cmdargs = @($cmdargs | Where-Object { @("-amd64", "-x86", "-x64") -notcontains $_ })

if(!$cmd) {
    _WriteOut "You must specify a command!"
    $cmd = "help"
    $Script:ExitCode = $ExitCodes.InvalidArguments
}

# Check for the command and run it
try {
    if(Get-Command -Name "$CommandPrefix$cmd" -ErrorAction SilentlyContinue) {
        _WriteDebug "& dnvm-$cmd $cmdargs"
        & "dnvm-$cmd" @cmdargs
    }
    else {
        _WriteOut "Unknown command: '$cmd'"
        dnvm-help
        $Script:ExitCode = $ExitCodes.UnknownCommand
    }
} catch {
    Write-Error $_
    if(!$Script:ExitCode) { $Script:ExitCode = $ExitCodes.OtherError }
}

_WriteDebug "=== End $CommandName (Exit Code $Script:ExitCode) ==="
_WriteDebug ""
exit $Script:ExitCode
