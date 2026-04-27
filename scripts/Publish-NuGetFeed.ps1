[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackageFilePath,

    [Parameter(Mandatory)]
    [string]$FeedSourceUrl,

    [string]$FeedName = 'NuGet feed',
    [string]$NuGetExePath = 'nuget.exe',
    [string]$ApiKey = $env:NUGET_PUBLISH_TOKEN,

    [switch]$PromoteToRelease
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[$(Get-Date -Format o)] $Message"
}

function Invoke-LoggedCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory = (Get-Location).Path
    )

    Write-Step ("Running: {0} {1}" -f $FilePath, ($Arguments -join ' '))
    Push-Location $WorkingDirectory
    try {
        & $FilePath @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            throw "$FilePath exited with code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

function Get-NuGetPackageIdentity {
    param([Parameter(Mandatory)][string]$Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $nuspec = $zip.Entries | Where-Object { $_.FullName -like '*.nuspec' } | Select-Object -First 1
        if (-not $nuspec) {
            throw "No nuspec was found in $Path"
        }

        $reader = [IO.StreamReader]::new($nuspec.Open())
        try {
            [xml]$nuspecXml = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        $idNode = $nuspecXml.SelectSingleNode('//*[local-name()="metadata"]/*[local-name()="id"]')
        $versionNode = $nuspecXml.SelectSingleNode('//*[local-name()="metadata"]/*[local-name()="version"]')
        if (-not $idNode -or -not $versionNode) {
            throw "Package identity was not found in $($nuspec.FullName)"
        }

        return [pscustomobject]@{
            Id = [string]$idNode.InnerText
            Version = [string]$versionNode.InnerText
        }
    }
    finally {
        $zip.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $PackageFilePath -PathType Leaf)) {
    throw "Package file was not found at $PackageFilePath"
}

if (-not $ApiKey) {
    throw 'NUGET_PUBLISH_TOKEN was not provided. Store the PAT as a secret pipeline variable and map it to this environment variable.'
}

Write-Step "Publishing $PackageFilePath to $FeedName"
Invoke-LoggedCommand -FilePath $NuGetExePath -Arguments @(
    'push', $PackageFilePath,
    '-Source', $FeedSourceUrl,
    '-ApiKey', $ApiKey,
    '-NonInteractive',
    '-Verbosity', 'detailed'
) -WorkingDirectory (Split-Path -Parent $PackageFilePath)

if ($PromoteToRelease) {
    Write-Step "PromoteToRelease=true for $FeedName. Configure feed views or release promotion policy in Azure DevOps/TFS for this source."
}

$identity = Get-NuGetPackageIdentity -Path $PackageFilePath
Invoke-LoggedCommand -FilePath $NuGetExePath -Arguments @('list', $identity.Id, '-Source', $FeedSourceUrl, '-AllVersions', '-NonInteractive') -WorkingDirectory (Split-Path -Parent $PackageFilePath)
