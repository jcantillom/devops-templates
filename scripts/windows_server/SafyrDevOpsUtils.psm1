if (-not (Get-Module -Name IISAdministration)) {
    Import-Module IISAdministration -UseWindowsPowerShell -Force -WarningAction SilentlyContinue
}

if (-not (Get-Module -Name WebAdministration)) {
    Import-Module WebAdministration -UseWindowsPowerShell -Force -WarningAction SilentlyContinue
}

function Add-LogEntry {
    param (
        [System.Collections.Concurrent.ConcurrentBag[object]]$LogList,
        [string]$SiteName,
        [string]$Message,
        [bool]$IsError = $false
    )
    $LogList.Add([PSCustomObject]@{
        Site      = $SiteName
        Message   = $Message
        Timestamp = [DateTime]::Now
        IsError   = $IsError
    })
}

function Get-VariableGroupUrl {  
    $baseUrl = "$($env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI)$($env:SYSTEM_TEAMPROJECTID)/_apis/distributedtask/variablegroups/"
    $apiVersion = "?api-version=7.1-preview.1"
    $url = $baseUrl + $env:VARIABLEGROUPID + $apiVersion
    
    return $url
}

function Get-DevOpsAuthHeader {
    return @{
        "Authorization" = "Bearer $env:SYSTEM_ACCESSTOKEN"
        "Content-Type"  = "application/json"
        "Accept"        = "application/json"
    }
}

function Get-VariableGroup {
    $url = Get-VariableGroupUrl
    $header = Get-DevOpsAuthHeader

    $response = Invoke-RestMethod -Uri $url -Headers $header -Method Get

    return @{
        id        = $response.id
        name      = $response.name
        type      = "Vsts"
        variables = $response.variables
    }
}

function Get-CurrentVersionFromGroup {
    param (
        [string]$tag
    )

    $group = Get-VariableGroup

    $majorObj = Get-VariableValueFromGroup -variables $group.variables -key "major"
    $major = if ($majorObj) { [int]$majorObj.Value } else { 1 }

    $minorObj = Get-VariableValueFromGroup -variables $group.variables -key "minor-$tag"
    $minor = if ($minorObj) { [int]$minorObj.Value } else { -1 }

    $patchObj = Get-VariableValueFromGroup -variables $group.variables -key "patch-$tag"
    $patch = if ($patchObj) { [int]$patchObj.Value } else { -1 }

    return [PSCustomObject]@{
        Major = $major
        Minor = $minor
        Patch = $patch
        Tag = $tag
    }
}

function Get-NuGetVersionString {
    param (
        [Parameter(Mandatory)]
        [pscustomobject]$VersionObject
    )

    $major = $VersionObject.Major
    $minor = $VersionObject.Minor
    $patch = $VersionObject.Patch
    $tag   = $VersionObject.Tag

    $version = "$major.$minor.$patch"

    if ($tag -and $tag.Trim() -ne "prod") {
        $version += "-$tag"
    }

    return $version
}

function Get-VariableValueFromGroup {
    param (
        [object]$variables,
        [string]$key
    )

    if ($null -eq $variables) {
        Write-Host "🚫 El objeto 'variables' es null. No se puede acceder." -ForegroundColor Red
        return $null
    }

    if (-not ($variables -is [hashtable])) {
        $temp = @{}
        foreach ($entry in $variables.PSObject.Properties) {
            $temp[$entry.Name] = $entry.Value
        }
        $variables = $temp
    }

    if ($variables.ContainsKey($key)) {
        return @{
            Name  = $key
            Value = $variables[$key].value
        }
    }

    return $null
}

function Set-VariableValueInGroup {
    param (
        [ref]$variables,
        [string]$key,
        [string]$newValue
    )

    if ($null -eq $variables.Value) {
        Write-Host "🚫 El objeto 'variables' es null. Inicializando..."
        $variables.Value = @{ }
    }

    if (-not ($variables.Value -is [hashtable])) {
        Write-Host "🔁 Convirtiendo PSCustomObject a Hashtable..."
        $converted = @{}
        foreach ($entry in $variables.Value.PSObject.Properties) {
            if ($entry.Value -is [psobject] -and $entry.Value.PSObject.Properties.Match('value')) {
                $converted[$entry.Name] = $entry.Value
            } else {
                $converted[$entry.Name] = @{ value = $entry.Value }
            }
        }
        $variables.Value = $converted
    }

    if ($variables.Value.ContainsKey($key)) {
        $variables.Value[$key].value = $newValue
    } else {
        $variables.Value[$key] = @{ value = $newValue }
    }

    return $variables.Value
}

function Update-VariableGroup {
    param (
        [object]$UpdatedGroup
    )

    $url = Get-VariableGroupUrl
    $header = Get-DevOpsAuthHeader
    $body = $UpdatedGroup | ConvertTo-Json -Depth 10

    $response = Invoke-RestMethod -Uri $url -Headers $header -Method Put -Body $body
}

function Confirm-FilesInTargetDirectories {
    param (
        [string[]]$Directories,
        [string[]]$ModifiedFiles
    )

    $containsSpecificPaths = $false

    foreach ($file in $ModifiedFiles) {
        foreach ($dir in $Directories) {
            if ($file -like "$dir*") {
                $containsSpecificPaths = $true
                break
            }
        }
    }

    return $containsSpecificPaths
}
function Get-DifferentBranchesFromCommit {
    param (
        [string[]]$ModifiedFiles,
        [string]$MergeCommitId,
        [string]$CurrentBranch,        
        [array]$BranchCollection
    )

    $branchesDifferent = @()

    foreach ($file in $ModifiedFiles) {
        $lastCommit = git log -n 1 --pretty=format:"%h" $MergeCommitId -- $file
        $branches = git branch -r --contains $lastCommit

        foreach ($branch in $branches) {
            $branchName = ($branch.Trim()) -replace '^origin/', ''            
            $tag = Get-TagFromBranch -branchCollection $BranchCollection -branchName $branchName
            if (
                $branchName -ne $CurrentBranch -and
                -not $branchesDifferent.Contains($branchName) -and
                [string]::IsNullOrWhiteSpace($tag)
            ) {
                $branchesDifferent += $branchName
            }
        }
    }

    return $branchesDifferent
}

function Set-VersionFlags {
    param (
        [string[]]$Branches
    )

    $result = [PSCustomObject]@{
        IsPatch = $false
        IsMinor = $false
    }

    foreach ($branch in $Branches) {
        if ($branch.StartsWith("bugfix/") -or $branch.StartsWith("hotfix/")) {
            $result.IsPatch = $true
        } else {
            $result.IsMinor = $true
        }
    }

    return $result
}

function Get-Branches {
    $group = Get-VariableGroup
    $branchesObj = Get-VariableValueFromGroup -variables $group.variables -key "branches"
    $branches = if ($branchesObj) { $branchesObj.Value | ConvertFrom-Json } else { @() }
    return $branches
}

function Get-TagFromBranch {
    param (
        [array]$branchCollection,
        [string]$branchName
    )

    $match = $branchCollection | Where-Object { $_.branch -eq $branchName }
    if ($null -ne $match) {
        return $match.tag
    } else {
        return ""
    }
}

function Get-BranchState {
    param (
        [array]$branchCollection,
        [string]$branchName
    )

    $match = $branchCollection | Where-Object { $_.branch -eq $branchName }
    if ($null -ne $match) {
        return [bool]$match.enable
    } else {
        return $false
    }
}

function Get-MergeVersionInfo {
    param (
        [string]$currentBranch,
        [string]$tag
    )

    $group = Get-VariableGroup
    
    $directoriesJson = Get-VariableValueFromGroup -variables $group.variables -key "directoriesToTrack"
    $directories = if ($directoriesJson) { $directoriesJson.Value | ConvertFrom-Json } else { @() }

    $branchCollection = Get-Branches

    $mergeCommitId = git log origin/$currentBranch --merges -1 --pretty=format:"%h"
    $parentCommitDestinationId, $parentCommitOriginId = (git show $mergeCommitId --pretty=format:"%P") -split " "
    $modifiedFiles = @(
        git diff --name-only $parentCommitDestinationId $mergeCommitId | ForEach-Object { $_.Trim() }
    )

    Write-Host "🧾 Último commit de merge: $mergeCommitId" -ForegroundColor Cyan
    Write-Host "🧾 Commit de merge (Padre destino): $parentCommitDestinationId" -ForegroundColor Cyan
    Write-Host "🧾 Commit de merge (Padre origen): $parentCommitOriginId" -ForegroundColor Cyan
    
    Write-Host "📂 Archivos modificados:" -ForegroundColor Cyan
    if ($modifiedFiles.Count -gt 0) {
        foreach ($file in $modifiedFiles) {
            Write-Host "   $file"
        }
    } else {
        Write-Host "   No se encontraron archivos modificados." -ForegroundColor Red
    }

    $containsSpecificPaths = Confirm-FilesInTargetDirectories -Directories $directories -ModifiedFiles $modifiedFiles
    Write-Host "📁 ¿Archivos en directorios específicos?: $containsSpecificPaths" -ForegroundColor Cyan

    if (-not $containsSpecificPaths) {
        return @{
            containsSpecificPaths = $false
        }
    }

    $branchesDifferent = Get-DifferentBranchesFromCommit -ModifiedFiles $modifiedFiles -MergeCommitId $mergeCommitId -CurrentBranch $currentBranch -BranchCollection $branchCollection
    Write-Host "🌿 Ramas diferentes a la actual:" -ForegroundColor Cyan
    if ($branchesDifferent.Count -gt 0) {
        foreach ($branch in $branchesDifferent) {
            Write-Host "   $branch"
        }
    } else {
        Write-Host "   No se encontraron ramas diferentes." -ForegroundColor Red
    }

    $versionFlags = $null
    $nugetVersion = $null

    $newVersion = Get-CurrentVersionFromGroup -tag $tag

    if ($containsSpecificPaths) {
        $versionFlags = Set-VersionFlags -Branches $branchesDifferent

        Write-Host "🧩 Tipo de versión detectado:"
        if ($versionFlags.IsPatch -and -not $versionFlags.IsMinor) {
            Write-Host "   🔧 Incrementando versión *patch*"
            $newVersion.Patch += 1
            if ($newVersion.Minor -lt 0) {
                $newVersion.Minor = 0
            }
        } else {
            Write-Host "   ✨ Incrementando versión *minor*"
            $newVersion.Minor += 1
            $newVersion.Patch = 0
        }

        $nugetVersion = Get-NuGetVersionString -VersionObject $newVersion
        Write-Host "📦 NuGet version: $nugetVersion"
    }   

    return @{
        containsSpecificPaths = $containsSpecificPaths
        versionFlags          = $versionFlags
        newVersion            = $newVersion
        nugetVersion          = $nugetVersion 
    }
}

function Get-SitesByHostName {
    param (
        [string]$hostname,
        [string]$stage
    )

    $group = Get-VariableGroup
    
    $sitesObj = Get-VariableValueFromGroup -variables $group.variables -key "sites"
    $allSites = if ($sitesObj) { $sitesObj.Value | ConvertFrom-Json } else { @() }
    
    $matchedSites = $allSites | Where-Object {
        $_.HostNames -contains $hostname -and $_.Stage -eq $stage
    }
    
    return $matchedSites
}

function Get-WebAppStatus {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SiteName,
        [System.Collections.Concurrent.ConcurrentBag[object]]$LogList
    )
    
    $site = Get-Website -Name $SiteName

    if ($site) {
        $state = $site.State
        Add-LogEntry -LogList $LogList -SiteName $SiteName -Message "🌐 Estado del sitio: 🟢 $state"
        return $state -eq 'Started' 
    } else {
        Add-LogEntry -LogList $LogList -SiteName $SiteName -Message "⚠️ El sitio no existe."
    }

    return $false
}

function Stop-WebApp {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SiteName,
        [System.Collections.Concurrent.ConcurrentBag[object]]$LogList
    )

    $site = Get-Website -Name $SiteName
    if ($site) {
        Stop-WebSite -Name $SiteName

        do {
            Start-Sleep -Seconds 5
            $state = Get-WebsiteState -Name $SiteName 
        } while ($state.Value -ne 'Stopped')

        Add-LogEntry -LogList $LogList -SiteName $SiteName -Message "🛑 El sitio fue detenido."
    } else {
        Add-LogEntry -LogList $LogList -SiteName $SiteName -Message "❌ El sitio no fue encontrado." -IsError $true
    }
}

function Start-WebApp {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SiteName,
        [System.Collections.Concurrent.ConcurrentBag[object]]$LogList
    )

    $site = Get-Website -Name $SiteName
    if ($site) {
        Start-WebSite -Name $SiteName
        Add-LogEntry -LogList $LogList -SiteName $SiteName -Message "✅ El sitio fue iniciado."
    } else {
        Add-LogEntry -LogList $LogList -SiteName $SiteName -Message "❌ El sitio no fue encontrado." -IsError $true
    }
}

function Get-AppPoolNames {
    param (
        [string]$Filter = ''
    )

    $appPools = Get-IISAppPool | Where-Object {
        $_.Name -like "*$Filter*"
    } | Select-Object -ExpandProperty Name

    return $appPools
}

function Stop-AppPools {
    param (
        [string[]]$PoolNames,
        [string]$AppName,
        [System.Collections.Concurrent.ConcurrentBag[object]]$LogList
    )

    foreach ($name in $PoolNames) {
        $pool = Get-IISAppPool | Where-Object { $_.Name -eq $name }
        if ($pool) {
            if ($pool.State -ne 'Stopped') {
                Add-LogEntry -LogList $LogList -SiteName $AppName -Message "🛑 Deteniendo pool: $name"
                Stop-WebAppPool -Name $name
            } else {
                Add-LogEntry -LogList $LogList -SiteName $AppName -Message "⚠️ El pool '$name' ya estaba detenido."
            }
        } else {
            Add-LogEntry -LogList $LogList -SiteName $AppName -Message "❌ El pool '$name' no existe." -IsError $true
        }
    }
}

function Start-AppPools {
    param (
        [string[]]$PoolNames,
        [string]$AppName,
        [System.Collections.Concurrent.ConcurrentBag[object]]$LogList
    )

    foreach ($name in $PoolNames) {
        $pool = Get-IISAppPool | Where-Object { $_.Name -eq $name }
        if ($pool) {
            if ($pool.State -ne 'Started') {
                Add-LogEntry -LogList $LogList -SiteName $AppName -Message "🚀 Iniciando pool: $name"
                Start-WebAppPool -Name $name
            } else {
                Add-LogEntry -LogList $LogList -SiteName $AppName -Message "✅ El pool '$name' ya estaba iniciado."
            }
        } else {
            Add-LogEntry -LogList $LogList -SiteName $AppName -Message "❌ El pool '$name' no existe." -IsError $true
        }
    }
}

function Get-TaskStatus {
    param (
        [string]$TaskName,
        [System.Collections.Concurrent.ConcurrentBag[object]]$LogList
    )

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    if ($task) {
        Add-LogEntry -LogList $LogList -SiteName $TaskName -Message "🔍 Estado de la tarea: $($task.State)"
        return $task.State -eq 'Running'
    } else {
        Add-LogEntry -LogList $LogList -SiteName $TaskName -Message "⚠️ Tarea no encontrada."
    }

    return $false
}

function Stop-Task {
    param (
        [string]$TaskName,
        [System.Collections.Concurrent.ConcurrentBag[object]]$LogList
    )

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName

        do {
            Start-Sleep -Seconds 5
            $task = Get-ScheduledTask -TaskName $TaskName
            $status = $task.State
        } while ($status -eq 'Running')

        Add-LogEntry -LogList $LogList -SiteName $TaskName -Message "🛑 Tarea detenida."
    } else {
        Add-LogEntry -LogList $LogList -SiteName $TaskName -Message "❌ La tarea no fue encontrada." -IsError $true
    }
}

function Start-Task {
    param (
        [string]$TaskName,
        [System.Collections.Concurrent.ConcurrentBag[object]]$LogList
    )

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Start-ScheduledTask -TaskName $TaskName
        Add-LogEntry -LogList $LogList -SiteName $TaskName -Message "✅ Tarea iniciada."
    } else {
        Add-LogEntry -LogList $LogList -SiteName $TaskName -Message "❌ La tarea no fue encontrada." -IsError $true
    }
}

function Publish-FilesApp {
    param (
        [Parameter(Mandatory = $true)]
        [string]$sourcePath,
        [Parameter(Mandatory = $true)]
        [string]$destinationPath,
        [System.Collections.Concurrent.ConcurrentBag[object]]$LogList,
        [string]$SiteName
    )

    if (Test-Path $sourcePath) {
        if (-not (Test-Path $destinationPath)) {
            New-Item -ItemType Directory -Path $destinationPath | Out-Null
            Add-LogEntry -LogList $LogList -SiteName $SiteName -Message "📁 Directorio destino creado: $destinationPath"
        }

        Copy-Item -Path "$sourcePath\*" -Destination $destinationPath -Recurse -Force
        Add-LogEntry -LogList $LogList -SiteName $SiteName -Message "📤 Archivos copiados desde '$sourcePath' hacia '$destinationPath'"
    } else {
        Add-LogEntry -LogList $LogList -SiteName $SiteName -Message "❌ El origen '$sourcePath' no existe." -IsError $true
    }
}

function Publish-Application {
    param (
        [Parameter(Mandatory = $true)]
        [object]$site,
        [Parameter(Mandatory = $true)]
        [System.Collections.Concurrent.ConcurrentBag[object]]$LogList
    )

    $source = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY $site.FolderTemp
    $destination = $site.DirectoryDeploy

    Add-LogEntry -LogList $LogList -SiteName $site.ApplicationName -Message "📦 Iniciando publicación..."

    switch ($site.Type) {
        "IIS" {            
            if (Get-WebAppStatus -SiteName $site.ApplicationName -LogList $LogList) {
                Add-LogEntry -LogList $LogList -SiteName $site.ApplicationName -Message "🔁 Sitio IIS iniciado. Reiniciando AppPools..."

                $pools = Get-AppPoolNames -Filter $site.ApplicationName
                Stop-AppPools -PoolNames $pools -AppName $site.ApplicationName -LogList $LogList
                Stop-WebApp -SiteName $site.ApplicationName -LogList $LogList
                Start-Sleep -Seconds 3

                Publish-FilesApp -sourcePath $source -destinationPath $destination -LogList $LogList -SiteName $site.ApplicationName

                Start-AppPools -PoolNames $pools -AppName $site.ApplicationName -LogList $LogList
                Start-WebApp -SiteName $site.ApplicationName -LogList $LogList

                Add-LogEntry -LogList $LogList -SiteName $site.ApplicationName -Message "✅ Publicación completada (IIS)"
            } else {
                Add-LogEntry -LogList $LogList -SiteName $site.ApplicationName -Message "⚠️ Sitio IIS no iniciado. Publicando sin reinicio."
                Publish-FilesApp -sourcePath $source -destinationPath $destination -LogList $LogList -SiteName $site.ApplicationName
            }
            break
        }

        "TaskScheduler" {
            if (Get-TaskStatus -TaskName $site.ApplicationName -LogList $LogList) {
                Add-LogEntry -LogList $LogList -SiteName $site.ApplicationName -Message "🔁 Tarea activa. Deteniendo temporalmente..."

                Stop-Task -TaskName $site.ApplicationName -LogList $LogList
                Start-Sleep -Seconds 10

                Publish-FilesApp -sourcePath $source -destinationPath $destination -LogList $LogList -SiteName $site.ApplicationName

                Start-Task -TaskName $site.ApplicationName -LogList $LogList

                Add-LogEntry -LogList $LogList -SiteName $site.ApplicationName -Message "✅ Publicación completada (Tarea)"
            } else {
                Add-LogEntry -LogList $LogList -SiteName $site.ApplicationName -Message "⚠️ Tarea no activa. Publicando sin detener."
                Publish-FilesApp -sourcePath $source -destinationPath $destination -LogList $LogList -SiteName $site.ApplicationName
            }
            break
        }

        default {
            Add-LogEntry -LogList $LogList -SiteName $site.ApplicationName -Message "❓ Tipo de despliegue desconocido: $($site.Type)" -IsError $true
        }
    }
}

function Remove-UnnecessaryResources {
    $group = Get-VariableGroup

    $pathsJson = Get-VariableValueFromGroup -variables $group.variables -key "pathsToRemove"
    $pathsToRemove = if ($pathsJson) { $pathsJson.Value | ConvertFrom-Json } else { @() }

    if (-not $pathsToRemove -or $pathsToRemove.Count -eq 0) {
        Write-Host "⚠️ No se encontraron rutas en la variable 'pathsToRemove'."
        return
    }
    
    foreach ($relativePath in $pathsToRemove) {
        $fullPath = Join-Path -Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY -ChildPath $relativePath

        if (Test-Path $fullPath) {
            if ((Get-Item $fullPath).PSIsContainer) {
                Write-Host "🗑️ Eliminando carpeta: $fullPath"
                Remove-Item $fullPath -Recurse -Force
            } else {
                Write-Host "🗑️ Eliminando archivo: $fullPath"
                Remove-Item $fullPath -Force
            }
        } else {
            Write-Host "❌ No encontrado: $fullPath"
        }
    }
}