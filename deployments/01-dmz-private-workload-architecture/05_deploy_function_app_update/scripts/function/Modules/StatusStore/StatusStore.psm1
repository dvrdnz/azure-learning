# StatusStore.psm1

$script:StatusContainerName = 'status'

function Get-StorageContext {
    if (-not $env:AzureWebJobsStorage) {
        throw 'AzureWebJobsStorage ist nicht verfügbar.'
    }
    return New-AzStorageContext -ConnectionString $env:AzureWebJobsStorage
}

function Set-OperationStatus {
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Status,
        [string]$Message = '',
        [Parameter(Mandatory)][string]$RequestedAt
    )

    $ctx = Get-StorageContext

    Invoke-WithRetry -OperationName 'New-AzStorageContainer(status)' -ScriptBlock {
        New-AzStorageContainer -Name $script:StatusContainerName -Context $ctx -Permission Off -ErrorAction SilentlyContinue | Out-Null
    }

    $statusRank = @{ 'Queued' = 1; 'Running' = 2; 'Succeeded' = 3; 'Failed' = 3 }
    $existingRaw = Get-OperationStatus -OperationId $OperationId
    if ($existingRaw) {
        $existing = $existingRaw | ConvertFrom-Json
        if ($statusRank.ContainsKey($existing.status) -and $statusRank.ContainsKey($Status) `
                -and $statusRank[$existing.status] -gt $statusRank[$Status]) {
            Write-Host "INFO [$OperationId]: Status-Write '$Status' übersprungen - vorhandener Status '$($existing.status)' ist bereits weiter fortgeschritten."
            return
        }
    }

    $body = @{
        operationId = $OperationId
        state       = $State
        status      = $Status
        message     = $Message
        requestedAt = $RequestedAt
        updatedAt   = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Compress

    $temp = Join-Path $env:TEMP "$OperationId.json"
    try {
        Set-Content -Path $temp -Value $body -NoNewline -Encoding UTF8
        Invoke-WithRetry -OperationName 'Set-AzStorageBlobContent(status)' -ScriptBlock {
            Set-AzStorageBlobContent -Container $script:StatusContainerName -Blob "$OperationId.json" -File $temp -Context $ctx -Force | Out-Null
        }
    }
    finally {
        Remove-Item -Path $temp -ErrorAction SilentlyContinue
    }
}

function Get-OperationStatus {
    param(
        [Parameter(Mandatory)][string]$OperationId
    )

    $ctx = Get-StorageContext
    $blob = Invoke-WithRetry -OperationName 'Get-AzStorageBlob(status)' -ScriptBlock {
        Get-AzStorageBlob -Container $script:StatusContainerName -Blob "$OperationId.json" -Context $ctx -ErrorAction SilentlyContinue
    }

    if (-not $blob) {
        return $null
    }

    $temp = Join-Path $env:TEMP "$OperationId-read.json"
    try {
        Invoke-WithRetry -OperationName 'Get-AzStorageBlobContent(status)' -ScriptBlock {
            Get-AzStorageBlobContent -Container $script:StatusContainerName -Blob "$OperationId.json" -Context $ctx -Destination $temp -Force | Out-Null
        }
        return Get-Content -Path $temp -Raw
    }
    finally {
        Remove-Item -Path $temp -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Get-StorageContext, Set-OperationStatus, Get-OperationStatus
