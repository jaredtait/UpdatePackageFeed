[CmdletBinding()]
param(
    [string]$PackageConfigPath = '',
    [string]$PackageName = '',
    [string]$PackageVersion = '',
    [string]$CveId = '',

    [string]$TargetFramework = 'net481',
    [string]$DownloadDirectory = 'C:\Temp\DownloadNuGetPackages',
    [string]$PublicNuGetSource = 'https://api.nuget.org/v3/index.json',

    [string]$NuGetExePath = 'nuget.exe',
    [string]$PublishScriptPath = (Join-Path $PSScriptRoot 'Publish-NuGetFeed.ps1'),
    [string]$TestFeedSourceUrl = '',
    [string]$LiveFeedSourceUrl = '',

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

function Resolve-PackageName {
    param([string]$ConfigPath)

    if ($PackageName) {
        return $PackageName
    }

    if (-not $ConfigPath) {
        throw 'PackageName was not provided and PackageConfigPath is empty.'
    }

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Package config was not found at $ConfigPath"
    }

    [xml]$xml = Get-Content -LiteralPath $ConfigPath
    if ($ConfigPath.EndsWith('packages.config', [StringComparison]::OrdinalIgnoreCase)) {
        $firstPackage = $xml.SelectSingleNode('//*[local-name()="package"]')
        if ($firstPackage -and $firstPackage.Attributes['id']) {
            return [string]$firstPackage.Attributes['id'].Value
        }
    }

    $packageReference = $xml.SelectSingleNode('//*[local-name()="PackageReference"]')
    if ($packageReference -and $packageReference.Attributes['Include']) {
        return [string]$packageReference.Attributes['Include'].Value
    }

    throw "Could not infer a package name from $ConfigPath. Pass -PackageName explicitly."
}

function Resolve-LatestVersion {
    param([Parameter(Mandatory)][string]$Name)

    $flatContainerName = $Name.ToLowerInvariant()
    $versionIndexUrl = "https://api.nuget.org/v3-flatcontainer/$flatContainerName/index.json"
    Write-Step "Fetching latest stable version from $versionIndexUrl"
    $versionIndex = Invoke-RestMethod -Uri $versionIndexUrl -Method Get
    $stableVersions = @($versionIndex.versions | Where-Object { $_ -notmatch '-' })

    if ($stableVersions.Count -eq 0) {
        throw "No stable versions were found for $Name."
    }

    return [string]$stableVersions[-1]
}

$resolvedPackageName = Resolve-PackageName -ConfigPath $PackageConfigPath
if (-not $PackageVersion) {
    $PackageVersion = Resolve-LatestVersion -Name $resolvedPackageName
}

$artifactDirectory = if ($env:BUILD_ARTIFACTSTAGINGDIRECTORY) { $env:BUILD_ARTIFACTSTAGINGDIRECTORY } else { Join-Path ([IO.Path]::GetTempPath()) 'UpdatePackageFeedLogs' }
New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
$logPath = Join-Path $artifactDirectory ("nuget-cve-update-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

Start-Transcript -Path $logPath -Force | Out-Null
try {
    Write-Step "Starting NuGet CVE update workflow. CVE: $CveId"

    if (Test-Path -LiteralPath $DownloadDirectory) {
        Remove-Item -LiteralPath $DownloadDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $DownloadDirectory -Force | Out-Null

    Invoke-LoggedCommand -FilePath $NuGetExePath -Arguments @(
        'install', $resolvedPackageName,
        '-Version', $PackageVersion,
        '-OutputDirectory', $DownloadDirectory,
        '-Source', $PublicNuGetSource,
        '-Framework', $TargetFramework,
        '-DirectDownload',
        '-NonInteractive',
        '-Verbosity', 'detailed'
    ) -WorkingDirectory $DownloadDirectory

    $packageFile = Get-ChildItem -Path $DownloadDirectory -Filter "$resolvedPackageName.$PackageVersion.nupkg" -Recurse |
        Where-Object { $_.Name -notlike '*.symbols.nupkg' } |
        Select-Object -First 1

    if (-not $packageFile) {
        throw "Downloaded package file was not found for $resolvedPackageName $PackageVersion."
    }

    Invoke-LoggedCommand -FilePath $NuGetExePath -Arguments @('verify', $packageFile.FullName, '-Signatures', '-NonInteractive') -WorkingDirectory $DownloadDirectory

    if (-not (Test-Path -LiteralPath $PublishScriptPath -PathType Leaf)) {
        throw "Publish script was not found at $PublishScriptPath"
    }

    if ($TestFeedSourceUrl) {
        & $PublishScriptPath `
            -PackageFilePath $packageFile.FullName `
            -FeedSourceUrl $TestFeedSourceUrl `
            -FeedName 'TFS Test' `
            -PromoteToRelease:$PromoteToRelease
    }
    else {
        Write-Step 'Skipping TFS Test publish because TestFeedSourceUrl was not provided.'
    }

    if ($PublishToLive -and $LiveFeedSourceUrl) {
        & $PublishScriptPath `
            -PackageFilePath $packageFile.FullName `
            -FeedSourceUrl $LiveFeedSourceUrl `
            -FeedName 'TFS Live' `
            -PromoteToRelease:$PromoteToRelease
    }
    elseif ($PublishToLive) {
        throw 'PublishToLive was set, but LiveFeedSourceUrl was not provided.'
    }

    Write-Step "NuGet CVE update workflow completed. Log: $logPath"
}
finally {
    Stop-Transcript | Out-Null
}
