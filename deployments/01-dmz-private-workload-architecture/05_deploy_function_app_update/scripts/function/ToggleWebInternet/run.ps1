using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

$State = $Request.Query.State
if (-not $State) { $State = $Request.Body.State }
$State = ("$State").Trim().ToLowerInvariant()

if ($State -notin @('on', 'off')) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = "Parameter 'State' muss 'On' oder 'Off' sein."
    })
    return
}

$OperationId = [guid]::NewGuid().ToString()
$RequestedAt = (Get-Date).ToUniversalTime().ToString('o')

try {
    Set-OperationStatus -OperationId $OperationId -State $State -Status 'Queued' -RequestedAt $RequestedAt

    $queueMessage = @{
        operationId = $OperationId
        state       = $State
        requestedAt = $RequestedAt
    } | ConvertTo-Json -Compress

    Push-OutputBinding -Name QueueMessage -Value $queueMessage

    $responseBody = @{
        operationId = $OperationId
        status      = 'Queued'
        statusCheck = "GET /api/GetToggleWebInternetStatus?operationId=$OperationId&code=<function-key-status>"
    } | ConvertTo-Json -Compress

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::Accepted
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = $responseBody
    })
}
catch {
    Write-Host "FEHLER [$OperationId]: $($_.Exception.ToString())"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = (@{
            error       = 'Der Vorgang konnte nicht gestartet werden.'
            operationId = $OperationId
        } | ConvertTo-Json -Compress)
    })
}
