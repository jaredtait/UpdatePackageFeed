# UpdatePackageFeed

Automation for updating, validating, and publishing npm and NuGet packages after a CVE is detected in a security audit stage.

## Contents

- `pipelines/cve-package-update.yml` - Azure DevOps pipeline entry point.
- `scripts/Invoke-CveNpmUpdate.ps1` - npm/yarn CVE update, signature validation, and feed publish orchestration.
- `scripts/Publish-NpmFeed.ps1` - npm publish helper for TFS/Azure DevOps feeds.
- `scripts/Invoke-CveNuGetUpdate.ps1` - NuGet package download/update, signature validation, and feed publish orchestration.
- `scripts/Publish-NuGetFeed.ps1` - NuGet publish helper for TFS/Azure DevOps feeds.

## Pipeline Usage

Create secret pipeline variables for feed publishing:

- `NPM_PUBLISH_PAT`
- `NUGET_PUBLISH_PAT`

Run `pipelines/cve-package-update.yml` after the security audit detects a CVE. The audit stage can trigger this pipeline manually, through the Azure DevOps REST API, or by using it as a downstream template/stage.

Important pipeline parameters:

- `ecosystem`: `npm`, `nuget`, or `both`.
- `cveId`: CVE identifier for logging and traceability.
- `packageName`: package to update when running targeted mode.
- `packageVersion`: patched version for targeted mode. If omitted for targeted NuGet, the latest stable public version is fetched.
- `productionReady`: passes `PromoteToRelease=true` to publish scripts.
- `publishToLive`: publishes to the live feed after test feed publishing.
- `npmPackageJsonPath`: path to `package.json` when running npm manifest mode.
- `npmYarnLockPath`: optional path to `yarn.lock` for npm manifest validation.
- `nugetPackageConfigPath`: path to `packages.config` or `.csproj` when running NuGet manifest mode.
- Feed URL parameters for TFS Test and TFS Live npm/NuGet feeds.

## Input Modes

The pipeline and scripts accept either targeted package input or manifest input.

Targeted mode:

- npm: provide `packageName` and `packageVersion`.
- NuGet: provide `packageName` and optionally `packageVersion`; the latest stable public NuGet version is used when `packageVersion` is empty.

Manifest mode:

- npm: provide `npmPackageJsonPath`. The script reads `dependencies`, `devDependencies`, `optionalDependencies`, and `peerDependencies`, installs them, validates npm signatures, creates package tarballs with `npm pack`, and publishes those tarballs.
- NuGet: provide `nugetPackageConfigPath`. The script reads every package from `packages.config` or every `PackageReference` from `.csproj`, downloads each package, validates signatures, and publishes each `.nupkg`.

## npm Flow

`Invoke-CveNpmUpdate.ps1` performs these steps:

1. Clears `C:\Temp\npmpublish` and `C:\Temp\yarncache` by default.
2. Uses either a targeted package/version or copies `package.json` and optional `yarn.lock` into the npm staging directory.
3. Writes `.npmrc` for the public npm registry.
4. Runs `yarn add package@version` for targeted mode, or `yarn install` for manifest mode. When a lockfile is supplied, the install uses `--frozen-lockfile`.
5. Removes read-only attributes under the Yarn cache and grants permissions on the `v6` cache folder when present.
6. Runs `npm audit signatures`.
7. Runs `npm pack` for the selected package or manifest packages.
8. Publishes package tarballs to the TFS Test feed and optionally the TFS Live feed.
9. Runs a feed lookup after publish and writes logs to the Azure Pipelines artifact staging directory.

Targeted example:

```powershell
pwsh scripts/Invoke-CveNpmUpdate.ps1 `
  -PackageName lodash `
  -PackageVersion 4.17.21 `
  -CveId CVE-2021-23337 `
  -TestFeedRegistryUrl "https://pkgs.dev.azure.com/org/project/_packaging/test/npm/registry/" `
  -LiveFeedRegistryUrl "https://pkgs.dev.azure.com/org/project/_packaging/live/npm/registry/" `
  -PromoteToRelease `
  -PublishToLive
```

Manifest example:

```powershell
pwsh scripts/Invoke-CveNpmUpdate.ps1 `
  -PackageJsonPath .\package.json `
  -YarnLockPath .\yarn.lock `
  -CveId CVE-2021-23337 `
  -TestFeedRegistryUrl "https://pkgs.dev.azure.com/org/project/_packaging/test/npm/registry/" `
  -LiveFeedRegistryUrl "https://pkgs.dev.azure.com/org/project/_packaging/live/npm/registry/" `
  -PromoteToRelease `
  -PublishToLive
```

## NuGet Flow

`Invoke-CveNuGetUpdate.ps1` performs these steps:

1. Accepts targeted package input, `packages.config` for .NET Framework apps, or `.csproj` files for SDK-style apps.
2. Fetches the latest stable version from NuGet.org when targeted `-PackageVersion` is not provided.
3. Downloads the package into `C:\Temp\DownloadNuGetPackages` by default.
4. Runs `nuget verify -Signatures`.
5. Publishes to the TFS Test feed and optionally the TFS Live feed.
6. Runs a feed lookup after publish and writes logs to the Azure Pipelines artifact staging directory.

Targeted example:

```powershell
pwsh scripts/Invoke-CveNuGetUpdate.ps1 `
  -PackageName Newtonsoft.Json `
  -PackageVersion 13.0.3 `
  -TargetFramework net481 `
  -TestFeedSourceUrl "https://pkgs.dev.azure.com/org/project/_packaging/test/nuget/v3/index.json" `
  -LiveFeedSourceUrl "https://pkgs.dev.azure.com/org/project/_packaging/live/nuget/v3/index.json" `
  -PromoteToRelease `
  -PublishToLive
```

Manifest example:

```powershell
pwsh scripts/Invoke-CveNuGetUpdate.ps1 `
  -PackageConfigPath .\packages.config `
  -TargetFramework net481 `
  -TestFeedSourceUrl "https://pkgs.dev.azure.com/org/project/_packaging/test/nuget/v3/index.json" `
  -LiveFeedSourceUrl "https://pkgs.dev.azure.com/org/project/_packaging/live/nuget/v3/index.json" `
  -PromoteToRelease `
  -PublishToLive
```

## Security Notes

- Store PATs as secret pipeline variables only. Do not commit them to the repository.
- The scripts map PATs through `NPM_PUBLISH_TOKEN` and `NUGET_PUBLISH_TOKEN`.
- Package authenticity is checked with `npm audit signatures` and `nuget verify -Signatures` before publishing.
- Live publishing is opt-in through `publishToLive`.
