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
- `packageName`: package to update.
- `packageVersion`: patched version. If omitted for NuGet, the latest stable public version is fetched.
- `productionReady`: passes `PromoteToRelease=true` to publish scripts.
- `publishToLive`: publishes to the live feed after test feed publishing.
- `npmInputDirectory`: directory containing `package.json` and `yarn.lock`.
- `nugetPackageConfigPath`: path to `packages.config` or `.csproj` when package name inference is needed.
- Feed URL parameters for TFS Test and TFS Live npm/NuGet feeds.

## npm Flow

`Invoke-CveNpmUpdate.ps1` performs these steps:

1. Clears `C:\Temp\npmpublish` and `C:\Temp\yarncache` by default.
2. Copies `package.json` and `yarn.lock` into the npm staging directory.
3. Writes `.npmrc` for the public npm registry.
4. Runs `yarn add package@version` when a package/version is provided, otherwise runs `yarn install --frozen-lockfile`.
5. Removes read-only attributes under the Yarn cache and grants permissions on the `v6` cache folder when present.
6. Runs `npm audit signatures`.
7. Publishes to the TFS Test feed and optionally the TFS Live feed.
8. Runs a feed lookup after publish and writes logs to the Azure Pipelines artifact staging directory.

Example:

```powershell
pwsh scripts/Invoke-CveNpmUpdate.ps1 `
  -PackageJsonPath .\package.json `
  -YarnLockPath .\yarn.lock `
  -PackageName lodash `
  -PackageVersion 4.17.21 `
  -CveId CVE-2021-23337 `
  -TestFeedRegistryUrl "https://pkgs.dev.azure.com/org/project/_packaging/test/npm/registry/" `
  -LiveFeedRegistryUrl "https://pkgs.dev.azure.com/org/project/_packaging/live/npm/registry/" `
  -PromoteToRelease `
  -PublishToLive
```

## NuGet Flow

`Invoke-CveNuGetUpdate.ps1` performs these steps:

1. Accepts `packages.config` for .NET Framework apps or `.csproj` files for SDK-style apps.
2. Fetches the latest stable version from NuGet.org when `-PackageVersion` is not provided.
3. Downloads the package into `C:\Temp\DownloadNuGetPackages` by default.
4. Runs `nuget verify -Signatures`.
5. Publishes to the TFS Test feed and optionally the TFS Live feed.
6. Runs a feed lookup after publish and writes logs to the Azure Pipelines artifact staging directory.

Example:

```powershell
pwsh scripts/Invoke-CveNuGetUpdate.ps1 `
  -PackageConfigPath .\packages.config `
  -PackageName Newtonsoft.Json `
  -PackageVersion 13.0.3 `
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
