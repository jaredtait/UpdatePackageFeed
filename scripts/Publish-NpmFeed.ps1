[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackageDirectory,

    [Parameter(Mandatory)]
    [string]$FeedRegistryUrl,

    [string]$FeedName = 'npm feed',
    [string]$Token = $env:NPM_PUBLISH_TOKEN,

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

if (-not (Test-Path -LiteralPath $PackageDirectory -PathType Container)) {
    throw "Package directory was not found at $PackageDirectory"
}

if (-not $Token) {
    throw 'NPM_PUBLISH_TOKEN was not provided. Store the PAT as a secret pipeline variable and map it to this environment variable.'
}

$registryUri = [Uri]$FeedRegistryUrl
$registryPath = $registryUri.AbsoluteUri -replace '^https?:', ''
$npmrcPath = Join-Path $PackageDirectory '.npmrc'

Add-Content -Path $npmrcPath -Value @(
    "registry=$FeedRegistryUrl"
    "$registryPath`:always-auth=true"
    "$registryPath`:_authToken=$Token"
) -Encoding ascii

Write-Step "Publishing package in $PackageDirectory to $FeedName"
Invoke-LoggedCommand -FilePath 'npm.cmd' -Arguments @('publish', '--registry', $FeedRegistryUrl) -WorkingDirectory $PackageDirectory

if ($PromoteToRelease) {
    Write-Step "PromoteToRelease=true for $FeedName. Configure feed views or release promotion policy in Azure DevOps/TFS for this registry."
}

$packageJson = Get-Content -LiteralPath (Join-Path $PackageDirectory 'package.json') -Raw | ConvertFrom-Json
$packageSpec = "$($packageJson.name)@$($packageJson.version)"
Invoke-LoggedCommand -FilePath 'npm.cmd' -Arguments @('view', $packageSpec, 'version', '--registry', $FeedRegistryUrl) -WorkingDirectory $PackageDirectory
