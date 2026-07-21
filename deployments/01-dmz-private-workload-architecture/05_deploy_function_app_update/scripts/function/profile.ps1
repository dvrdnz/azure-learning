# Azure Functions profile.ps1

if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    try {
        Connect-AzAccount -Identity | Out-Null
    }
    catch {
        Write-Host "WARNUNG: Connect-AzAccount im profile.ps1 fehlgeschlagen: $($_.Exception.Message)"
    }
}
