Import-Module -Name "$PSScriptRoot\SafyrDevOpsUtils.psm1" -Force

Set-Location -Path "$env:BUILD_SOURCESDIRECTORY/$env:PIPELINE_REPOSITORY_NAME"

$currentBranch = $env:BUILD_SOURCEBRANCHNAME

Write-Host "🌿 Rama actual: $currentBranch" -ForegroundColor Cyan

$branchCollection = Get-Branches

$tag = Get-TagFromBranch -branchCollection $branchCollection -branchName $currentBranch
Write-Host "🏷️ Tag correspondiente: $tag"

$enable = Get-BranchState -branchCollection $branchCollection -branchName $currentBranch

if (-not $enable) {
    Write-Host "❌ La rama '$currentBranch' no está activa." -ForegroundColor Red
    Write-Host "##vso[task.setvariable variable=containsSpecificPaths;]$false"
} else {
    $currentVersion = Get-CurrentVersionFromGroup -tag $tag
    Write-Host "📦 Versión actual: $($currentVersion.Major).$($currentVersion.Minor).$($currentVersion.Patch) 🏷️ $($currentVersion.Tag)"

    $result = Get-MergeVersionInfo -currentBranch $currentBranch -tag $tag

    Write-Host "##vso[task.setvariable variable=containsSpecificPaths;]$($result.containsSpecificPaths)"

    if ($result.containsSpecificPaths) {
        Write-Host "✅ Se detectaron cambios relevantes en rutas específicas."
        Write-Host "🧩 Tipo de versión:"
        Write-Host "   Patch: $($result.versionFlags.IsPatch)"
        Write-Host "   Minor: $($result.versionFlags.IsMinor)"
        Write-Host "📦 Nueva versión: $($result.newVersion.Major).$($result.newVersion.Minor).$($result.newVersion.Patch) 🏷️ $($result.newVersion.Tag)"

        $nugetVersion = Get-NuGetVersionString -VersionObject $result.newVersion
        Write-Host "📦 NuGet version: $nugetVersion"

        Write-Host "##vso[task.setvariable variable=major;]$($result.newVersion.Major)"
        Write-Host "##vso[task.setvariable variable=minor;]$($result.newVersion.Minor)"
        Write-Host "##vso[task.setvariable variable=patch;]$($result.newVersion.Patch)"
        Write-Host "##vso[task.setvariable variable=tag;]$($result.newVersion.Tag)"
        Write-Host "##vso[task.setvariable variable=nugetVersion;]$($result.nugetVersion)"
    }
    else {
        Write-Host "🔍 No se detectaron cambios relevantes en rutas específicas."
    }
}