$targetVersion = "v4.8"

Set-Location -Path "$env:BUILD_SOURCESDIRECTORY/$env:PIPELINE_REPOSITORY_NAME"

$solutionFile = $env:SOLUTION

Write-Host "solutionFile: $solutionFile"

if (-Not (Test-Path $solutionFile)) {
    Write-Host "⛔ No se encontro el archivo de solucion $solutionFile." -ForegroundColor Red
    exit
}

Write-Host "🔄 Obteniendo proyectos desde la solución: $solutionFile..."

$projects = (Get-Content $solutionFile) | Select-String -Pattern 'Project\("' 
    | ForEach-Object { ($_ -split '=')[1] -split ',' | Select-Object -Skip 1 -First 1 } 
    | ForEach-Object { $_ -replace '"', '' -replace '^\s+|\s+$', '' } 
    | Where-Object { $_ -match '\.vbproj$' -or $_ -match '\.csproj$' }

if ($projects.Count -eq 0) {
    Write-Host "⚠️ No se encontraron archivos de proyecto (.vbproj o .csproj) en la solución." -ForegroundColor Yellow
}
else {
    Write-Host "✅ Proyectos encontrados:"
    $projects | ForEach-Object { Write-Host "- $_" }

    foreach ($project in $projects) {
        $vbprojPath = (Resolve-Path $project).Path
        Write-Host "🔧 Actualizando TargetFrameworkVersion en: $vbprojPath..."

        if (Test-Path $vbprojPath) {            
            [xml]$xml = Get-Content $vbprojPath
            $propertyGroup = $xml.Project.PropertyGroup | Where-Object { $_.TargetFrameworkVersion }

            if ($propertyGroup) {
                $propertyGroup.TargetFrameworkVersion = $targetVersion
            } 
            else {
                $firstPropertyGroup = $xml.Project.PropertyGroup[0]
                $newNode = $xml.CreateElement("TargetFrameworkVersion")
                $newNode.InnerText = $targetVersion
                $firstPropertyGroup.AppendChild($newNode)
            }

            $xml.Save($vbprojPath)
            Write-Host "✅ TargetFrameworkVersion actualizado a $targetVersion en $vbprojPath"
        }
        else {
            Write-Host "⛔ No se encontró el archivo $vbprojPath. Omitido."
        }
    }
}