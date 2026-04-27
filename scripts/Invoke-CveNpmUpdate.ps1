[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackageJsonPath,

    [Parameter(Mandatory)]
    [string]$YarnLockPath,

    [string]$PackageName = '',
    [string]$PackageVersion = '',
    [string]$CveId = '',

    [string]$WorkspaceDirectory = 'C:\Temp\npmpublish',
    [string]$YarnCacheDirectory = 'C:\Temp\yarncache',
    [string]$NpmRegistry = 'https://registry.npmjs.org/',

    [string]$PublishScriptPath = (Join-Path $PSScriptRoot 'Publish-NpmFeed.ps1'),
    [string]$TestFeedRegistryUrl = '',
    [string]$LiveFeedRegistryUrl = '',

    [switch]$PromoteToRelease,
    [switch]$PublishToLive
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

function Clear-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Write-Step "Clearing $Path"
        Remove-Item -LiteralPath $Path -Recurse -Force
    }

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Remove-ReadOnlyAttributes {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    Write-Step "Removing read-only attributes under $Path"
    Get-ChildItem -LiteralPath $Path -Recurse -Force | ForEach-Object {
        if ($_.Attributes -band [IO.FileAttributes]::ReadOnly) {
            $_.Attributes = $_.Attributes -bxor [IO.FileAttributes]::ReadOnly
        }
    }
}

function Grant-CachePermissions {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $identity = if ($env:USERNAME) { $env:USERNAME } else { 'Users' }
    Write-Step "Granting cache permissions on $Path to $identity"
    Invoke-LoggedCommand -FilePath 'icacls.exe' -Arguments @($Path, '/grant', "$identity`:(OI)(CI)F", '/T', '/C') -WorkingDirectory $Path
}

if (-not (Test-Path -LiteralPath $PackageJsonPath -PathType Leaf)) {
    throw "package.json was not found at $PackageJsonPath"
}

if (-not (Test-Path -LiteralPath $YarnLockPath -PathType Leaf)) {
    throw "yarn.lock was not found at $YarnLockPath"
}

$artifactDirectory = if ($env:BUILD_ARTIFACTSTAGINGDIRECTORY) { $env:BUILD_ARTIFACTSTAGINGDIRECTORY } else { Join-Path ([IO.Path]::GetTempPath()) 'UpdatePackageFeedLogs' }
New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
$logPath = Join-Path $artifactDirectory ("npm-cve-update-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

Start-Transcript -Path $logPath -Force | Out-Null
try {
    Write-Step "Starting npm CVE update workflow. CVE: $CveId"

    Clear-Directory -Path $WorkspaceDirectory
    Clear-Directory -Path $YarnCacheDirectory

    Copy-Item -LiteralPath $PackageJsonPath -Destination (Join-Path $WorkspaceDirectory 'package.json') -Force
    Copy-Item -LiteralPath $YarnLockPath -Destination (Join-Path $WorkspaceDirectory 'yarn.lock') -Force

    $npmrcPath = Join-Path $WorkspaceDirectory '.npmrc'
    "registry=$NpmRegistry" | Set-Content -Path $npmrcPath -Encoding ascii
    Write-Step "Configured .npmrc for public npm registry: $NpmRegistry"

    if ($PackageName -and $PackageVersion) {
        Invoke-LoggedCommand -FilePath 'yarn.cmd' -Arguments @('add', "$PackageName@$PackageVersion", '--cache-folder', $YarnCacheDirectory, '--non-interactive') -WorkingDirectory $WorkspaceDirectory
    }
    else {
        Invoke-LoggedCommand -FilePath 'yarn.cmd' -Arguments @('install', '--frozen-lockfile', '--cache-folder', $YarnCacheDirectory, '--non-interactive') -WorkingDirectory $WorkspaceDirectory
    }

    Remove-ReadOnlyAttributes -Path $YarnCacheDirectory
    Grant-CachePermissions -Path (Join-Path $YarnCacheDirectory 'v6')

    Invoke-LoggedCommand -FilePath 'npm.cmd' -Arguments @('audit', 'signatures', '--registry', $NpmRegistry) -WorkingDirectory $WorkspaceDirectory

    if (-not (Test-Path -LiteralPath $PublishScriptPath -PathType Leaf)) {
        throw "Publish script was not found at $PublishScriptPath"
    }

    if ($TestFeedRegistryUrl) {
        & $PublishScriptPath `
            -PackageDirectory $WorkspaceDirectory `
            -FeedRegistryUrl $TestFeedRegistryUrl `
            -FeedName 'TFS Test' `
            -PromoteToRelease:$PromoteToRelease
    }
    else {
        Write-Step 'Skipping TFS Test publish because TestFeedRegistryUrl was not provided.'
    }

    if ($PublishToLive -and $LiveFeedRegistryUrl) {
        & $PublishScriptPath `
            -PackageDirectory $WorkspaceDirectory `
            -FeedRegistryUrl $LiveFeedRegistryUrl `
            -FeedName 'TFS Live' `
            -PromoteToRelease:$PromoteToRelease
    }
    elseif ($PublishToLive) {
        throw 'PublishToLive was set, but LiveFeedRegistryUrl was not provided.'
    }

    Write-Step "npm CVE update workflow completed. Log: $logPath"
}
finally {
    Stop-Transcript | Out-Null
}
