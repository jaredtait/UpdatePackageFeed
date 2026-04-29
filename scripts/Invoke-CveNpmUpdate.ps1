[CmdletBinding()]
param(
    [string]$PackageJsonPath = '',

    [string]$YarnLockPath = '',

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

function New-TargetPackageJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Version
    )

    $packageJson = [ordered]@{
        name = 'cve-npm-package-feed-update'
        version = '0.0.0-cve'
        private = $true
        dependencies = [ordered]@{
            $Name = $Version
        }
    }

    $packageJson | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding ascii
}

function Add-NpmPackageRequestsFromSection {
    param(
        [Parameter(Mandatory)][object]$PackageJson,
        [Parameter(Mandatory)][string]$SectionName,
        [Parameter(Mandatory)][hashtable]$Requests
    )

    $section = $PackageJson.PSObject.Properties[$SectionName]
    if (-not $section -or -not $section.Value) {
        return
    }

    foreach ($dependency in $section.Value.PSObject.Properties) {
        $versionSpec = [string]$dependency.Value
        if ($versionSpec -match '^(file:|link:|git\+|https?:|workspace:|\*)') {
            Write-Step "Skipping $($dependency.Name) from $SectionName because '$versionSpec' is not a concrete npm registry version or range."
            continue
        }

        if (-not $Requests.ContainsKey($dependency.Name)) {
            $Requests[$dependency.Name] = [pscustomobject]@{
                Name = $dependency.Name
                Version = $versionSpec
                Source = $SectionName
            }
        }
    }
}

function Resolve-NpmPackageRequests {
    param([Parameter(Mandatory)][string]$Path)

    if ($PackageName -and $PackageVersion) {
        return @([pscustomobject]@{
            Name = $PackageName
            Version = $PackageVersion
            Source = 'PackageName'
        })
    }

    $packageJson = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $requests = @{}
    Add-NpmPackageRequestsFromSection -PackageJson $packageJson -SectionName 'dependencies' -Requests $requests
    Add-NpmPackageRequestsFromSection -PackageJson $packageJson -SectionName 'devDependencies' -Requests $requests
    Add-NpmPackageRequestsFromSection -PackageJson $packageJson -SectionName 'optionalDependencies' -Requests $requests
    Add-NpmPackageRequestsFromSection -PackageJson $packageJson -SectionName 'peerDependencies' -Requests $requests

    if ($requests.Count -eq 0) {
        throw "No npm registry dependencies were found in $Path. Provide PackageName and PackageVersion for a targeted update."
    }

    return @($requests.Values | Sort-Object Name)
}

function Resolve-NpmInputMode {
    if ($PackageName -and $PackageVersion) {
        return 'TargetPackage'
    }

    if ($PackageName -xor $PackageVersion) {
        throw 'PackageName and PackageVersion must be provided together for targeted npm updates.'
    }

    if ($PackageJsonPath) {
        return 'PackageJson'
    }

    throw 'Provide either PackageName and PackageVersion, or PackageJsonPath.'
}

function New-NpmPackageTarball {
    param(
        [Parameter(Mandatory)][object]$Request,
        [Parameter(Mandatory)][string]$DestinationDirectory
    )

    New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    $beforePack = @(Get-ChildItem -LiteralPath $DestinationDirectory -Filter '*.tgz' -File -ErrorAction SilentlyContinue)
    $packageSpec = "$($Request.Name)@$($Request.Version)"
    Invoke-LoggedCommand -FilePath 'npm.cmd' -Arguments @('pack', $packageSpec, '--registry', $NpmRegistry, '--pack-destination', $DestinationDirectory) -WorkingDirectory $WorkspaceDirectory
    $afterPack = @(Get-ChildItem -LiteralPath $DestinationDirectory -Filter '*.tgz' -File)
    $newTarball = $afterPack |
        Where-Object { $beforePack.FullName -notcontains $_.FullName } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if (-not $newTarball) {
        throw "npm pack did not produce a tarball for $packageSpec."
    }

    return $newTarball.FullName
}

$artifactDirectory = if ($env:BUILD_ARTIFACTSTAGINGDIRECTORY) { $env:BUILD_ARTIFACTSTAGINGDIRECTORY } else { Join-Path ([IO.Path]::GetTempPath()) 'UpdatePackageFeedLogs' }
New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
$logPath = Join-Path $artifactDirectory ("npm-cve-update-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

Start-Transcript -Path $logPath -Force | Out-Null
try {
    Write-Step "Starting npm CVE update workflow. CVE: $CveId"
    $inputMode = Resolve-NpmInputMode
    Write-Step "Input mode: $inputMode"

    Clear-Directory -Path $WorkspaceDirectory
    Clear-Directory -Path $YarnCacheDirectory

    $workspacePackageJson = Join-Path $WorkspaceDirectory 'package.json'
    $tarballDirectory = Join-Path $WorkspaceDirectory 'tarballs'
    $hasYarnLock = $false

    if ($PackageJsonPath) {
        if (-not (Test-Path -LiteralPath $PackageJsonPath -PathType Leaf)) {
            throw "package.json was not found at $PackageJsonPath"
        }

        Copy-Item -LiteralPath $PackageJsonPath -Destination $workspacePackageJson -Force
    }
    else {
        New-TargetPackageJson -Path $workspacePackageJson -Name $PackageName -Version $PackageVersion
    }

    $packageRequests = @(Resolve-NpmPackageRequests -Path $workspacePackageJson)
    Write-Step ("Resolved {0} npm package request(s)." -f $packageRequests.Count)

    if ($YarnLockPath) {
        if (-not (Test-Path -LiteralPath $YarnLockPath -PathType Leaf)) {
            throw "yarn.lock was not found at $YarnLockPath"
        }

        Copy-Item -LiteralPath $YarnLockPath -Destination (Join-Path $WorkspaceDirectory 'yarn.lock') -Force
        $hasYarnLock = $true
    }

    $npmrcPath = Join-Path $WorkspaceDirectory '.npmrc'
    "registry=$NpmRegistry" | Set-Content -Path $npmrcPath -Encoding ascii
    Write-Step "Configured .npmrc for public npm registry: $NpmRegistry"

    if ($PackageName -and $PackageVersion) {
        Invoke-LoggedCommand -FilePath 'yarn.cmd' -Arguments @('add', "$PackageName@$PackageVersion", '--cache-folder', $YarnCacheDirectory, '--non-interactive') -WorkingDirectory $WorkspaceDirectory
    }
    elseif ($hasYarnLock) {
        Invoke-LoggedCommand -FilePath 'yarn.cmd' -Arguments @('install', '--frozen-lockfile', '--cache-folder', $YarnCacheDirectory, '--non-interactive') -WorkingDirectory $WorkspaceDirectory
    }
    else {
        Invoke-LoggedCommand -FilePath 'yarn.cmd' -Arguments @('install', '--cache-folder', $YarnCacheDirectory, '--non-interactive') -WorkingDirectory $WorkspaceDirectory
    }

    Remove-ReadOnlyAttributes -Path $YarnCacheDirectory
    Grant-CachePermissions -Path (Join-Path $YarnCacheDirectory 'v6')

    Invoke-LoggedCommand -FilePath 'npm.cmd' -Arguments @('audit', 'signatures', '--registry', $NpmRegistry) -WorkingDirectory $WorkspaceDirectory

    if (-not (Test-Path -LiteralPath $PublishScriptPath -PathType Leaf)) {
        throw "Publish script was not found at $PublishScriptPath"
    }

    foreach ($request in $packageRequests) {
        Write-Step "Packing npm package $($request.Name) $($request.Version)"
        $tarballPath = New-NpmPackageTarball -Request $request -DestinationDirectory $tarballDirectory
        $packageSpec = "$($request.Name)@$($request.Version)"

        if ($TestFeedRegistryUrl) {
            & $PublishScriptPath `
                -PackageTarballPath $tarballPath `
                -PackageSpec $packageSpec `
                -FeedRegistryUrl $TestFeedRegistryUrl `
                -FeedName 'TFS Test' `
                -PromoteToRelease:$PromoteToRelease
        }
        else {
            Write-Step 'Skipping TFS Test publish because TestFeedRegistryUrl was not provided.'
        }

        if ($PublishToLive -and $LiveFeedRegistryUrl) {
            & $PublishScriptPath `
                -PackageTarballPath $tarballPath `
                -PackageSpec $packageSpec `
                -FeedRegistryUrl $LiveFeedRegistryUrl `
                -FeedName 'TFS Live' `
                -PromoteToRelease:$PromoteToRelease
        }
        elseif ($PublishToLive) {
            throw 'PublishToLive was set, but LiveFeedRegistryUrl was not provided.'
        }
    }

    Write-Step "npm CVE update workflow completed. Log: $logPath"
}
finally {
    Stop-Transcript | Out-Null
}
