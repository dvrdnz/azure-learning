using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

$OperationId = $Request.Query.operationId
if (-not $OperationId) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = "Parameter 'operationId' fehlt."
    })
    return
}

$parsedGuid = [guid]::Empty
if (-not [guid]::TryParse($OperationId, [ref]$parsedGuid)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = "Parameter 'operationId' muss eine gültige GUID sein."
    })
    return
}
$OperationId = $parsedGuid.ToString()

try {
    $content = Get-OperationStatus -OperationId $OperationId

    if (-not $content) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body       = "Keine Statusinformation zu dieser operationId gefunden."
        })
        return
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = $content
    })
}
catch {
    Write-Host "FEHLER [$OperationId]: $($_.Exception.ToString())"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = (@{
            error       = 'Der Status konnte nicht abgerufen werden.'
            operationId = $OperationId
        } | ConvertTo-Json -Compress)
    })
}
