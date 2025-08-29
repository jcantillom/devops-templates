Import-Module -Name "$PSScriptRoot\SafyrDevOpsUtils.psm1" -Force

Write-Host "🌿 Stage recibido: $env:STAGE" -ForegroundColor Cyan

$hostname = $env:COMPUTERNAME
Write-Host "🏠 Hostname: $hostname" -ForegroundColor Green

$matchedSites = Get-SitesByHostName -hostname $hostname -stage $env:STAGE

$lines = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
$hasErrors = $false

if ($matchedSites.Count -gt 0) {
    $jobs = foreach ($site in $matchedSites) {
        Start-ThreadJob -ScriptBlock {
            param($site,  $sharedLines)

            Import-Module "$using:PSScriptRoot\SafyrDevOpsUtils.psm1" -Force
            
            Add-LogEntry -LogList $sharedLines -SiteName $site.ApplicationName -Message "📦 Iniciando publicación para el sitio"
            Add-LogEntry -LogList $sharedLines -SiteName $site.ApplicationName -Message "📂 Carpeta temporal: $($site.FolderTemp)"
            Add-LogEntry -LogList $sharedLines -SiteName $site.ApplicationName -Message "🚀 Directorio de despliegue: $($site.DirectoryDeploy)"
            Add-LogEntry -LogList $sharedLines -SiteName $site.ApplicationName -Message "🌿 Stage: $($site.Stage)"
            Add-LogEntry -LogList $sharedLines -SiteName $site.ApplicationName -Message "🖥️ Tipo: $($site.Type)"
                       
            try {
                Publish-Application -site $site -LogList $sharedLines
                Add-LogEntry -LogList $sharedLines -SiteName $site.ApplicationName -Message "✅ Publicación exitosa"
            } catch {
                Add-LogEntry -LogList $sharedLines -SiteName $site.ApplicationName -Message "❌ Error: $($_.Exception.Message)" -IsError $true
                Add-LogEntry -LogList $sharedLines -SiteName $site.ApplicationName -Message "📌 StackTrace: $($_.Exception.StackTrace)" -IsError $true
            }
            
        } -ArgumentList $site, $lines
    }

    $jobs | Wait-Job | Receive-Job | Out-Null
    $jobs | Remove-Job

    $sortedLines = $lines.ToArray() | Sort-Object Site, Timestamp

    $previousSite = ""

    foreach ($entry in $sortedLines) {
        if ($entry.Site -ne $previousSite) {
            Write-Host ""
            Write-Host ""
            $previousSite = $entry.Site
        }

        $color = if ($entry.IsError) { "Red" } else { "White" }
        Write-Host "[$($entry.Site)] $($entry.Message)" -ForegroundColor $color

        if ($entry.IsError) {
            $hasErrors = $true
        }
    }

    if ($hasErrors) {
        exit 1
    }

} else {
    Write-Host "🚫 No hay sitios asociados a este servidor." -ForegroundColor Red
}