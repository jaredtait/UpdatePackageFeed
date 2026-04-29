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

function Resolve-NuGetPackageRequests {
    param([string]$ConfigPath)

    if ($PackageName) {
        $resolvedVersion = $PackageVersion
        if (-not $resolvedVersion) {
            $resolvedVersion = Resolve-LatestVersion -Name $PackageName
        }

        return @([pscustomobject]@{
            Name = $PackageName
            Version = $resolvedVersion
            TargetFramework = $TargetFramework
        })
    }

    if (-not $ConfigPath) {
        throw 'Provide either PackageName and optional PackageVersion, or PackageConfigPath.'
    }

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Package config was not found at $ConfigPath"
    }

    $requests = @()
    [xml]$xml = Get-Content -LiteralPath $ConfigPath
    if ($ConfigPath.EndsWith('packages.config', [StringComparison]::OrdinalIgnoreCase)) {
        $packageNodes = @($xml.SelectNodes('//*[local-name()="package"]'))
        foreach ($packageNode in $packageNodes) {
            if (-not $packageNode.Attributes['id']) {
                continue
            }

            $name = [string]$packageNode.Attributes['id'].Value
            $version = if ($packageNode.Attributes['version']) { [string]$packageNode.Attributes['version'].Value } else { Resolve-LatestVersion -Name $name }
            $framework = if ($packageNode.Attributes['targetFramework']) { [string]$packageNode.Attributes['targetFramework'].Value } else { $TargetFramework }
            $requests += [pscustomobject]@{
                Name = $name
                Version = $version
                TargetFramework = $framework
            }
        }
    }
    else {
        $packageReferenceNodes = @($xml.SelectNodes('//*[local-name()="PackageReference"]'))
        foreach ($packageReference in $packageReferenceNodes) {
            if (-not $packageReference.Attributes['Include']) {
                continue
            }

            $name = [string]$packageReference.Attributes['Include'].Value
            $version = ''
            if ($packageReference.Attributes['Version']) {
                $version = [string]$packageReference.Attributes['Version'].Value
            }
            else {
                $versionNode = $packageReference.SelectSingleNode('*[local-name()="Version"]')
                if ($versionNode) {
                    $version = [string]$versionNode.InnerText
                }
            }

            if (-not $version) {
                $version = Resolve-LatestVersion -Name $name
            }

            $requests += [pscustomobject]@{
                Name = $name
                Version = $version
                TargetFramework = $TargetFramework
            }
        }
    }

    if ($requests.Count -gt 0) {
        return $requests
    }

    throw "No NuGet packages were found in $ConfigPath. Pass -PackageName explicitly."
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

$artifactDirectory = if ($env:BUILD_ARTIFACTSTAGINGDIRECTORY) { $env:BUILD_ARTIFACTSTAGINGDIRECTORY } else { Join-Path ([IO.Path]::GetTempPath()) 'UpdatePackageFeedLogs' }
New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
$logPath = Join-Path $artifactDirectory ("nuget-cve-update-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

Start-Transcript -Path $logPath -Force | Out-Null
try {
    Write-Step "Starting NuGet CVE update workflow. CVE: $CveId"
    $packageRequests = @(Resolve-NuGetPackageRequests -ConfigPath $PackageConfigPath)
    Write-Step ("Resolved {0} NuGet package request(s)." -f $packageRequests.Count)

    if (Test-Path -LiteralPath $DownloadDirectory) {
        Remove-Item -LiteralPath $DownloadDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $DownloadDirectory -Force | Out-Null

    if (-not (Test-Path -LiteralPath $PublishScriptPath -PathType Leaf)) {
        throw "Publish script was not found at $PublishScriptPath"
    }

    foreach ($request in $packageRequests) {
        Write-Step "Processing NuGet package $($request.Name) $($request.Version)"
        Invoke-LoggedCommand -FilePath $NuGetExePath -Arguments @(
            'install', $request.Name,
            '-Version', $request.Version,
            '-OutputDirectory', $DownloadDirectory,
            '-Source', $PublicNuGetSource,
            '-Framework', $request.TargetFramework,
            '-DirectDownload',
            '-NonInteractive',
            '-Verbosity', 'detailed'
        ) -WorkingDirectory $DownloadDirectory

        $packageFile = Get-ChildItem -Path $DownloadDirectory -Filter "$($request.Name).$($request.Version).nupkg" -Recurse |
            Where-Object { $_.Name -notlike '*.symbols.nupkg' } |
            Select-Object -First 1

        if (-not $packageFile) {
            throw "Downloaded package file was not found for $($request.Name) $($request.Version)."
        }

        Invoke-LoggedCommand -FilePath $NuGetExePath -Arguments @('verify', $packageFile.FullName, '-Signatures', '-NonInteractive') -WorkingDirectory $DownloadDirectory

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
    }

    Write-Step "NuGet CVE update workflow completed. Log: $logPath"
}
finally {
    Stop-Transcript | Out-Null
}
