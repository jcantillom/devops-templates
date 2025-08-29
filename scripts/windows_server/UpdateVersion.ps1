param (
    [int]$major,
    [int]$minor,
    [int]$patch,
    [string]$tag
)

Import-Module -Name "$PSScriptRoot\SafyrDevOpsUtils.psm1" -Force

Write-Host "🔧 Versión recibida: $major.$minor.$patch 🏷️ $tag"

$group = Get-VariableGroup

$group.variables = Set-VariableValueInGroup -variables ([ref]$group.variables) -key ("major") -newValue $major
$group.variables = Set-VariableValueInGroup -variables ([ref]$group.variables) -key ("minor-$tag") -newValue $minor
$group.variables = Set-VariableValueInGroup -variables ([ref]$group.variables) -key ("patch-$tag") -newValue $patch

Update-VariableGroup -UpdatedGroup $group