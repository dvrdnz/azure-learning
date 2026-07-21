# RetryHelper.psm1

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 4,
        [int]$InitialDelaySeconds = 2,
        [string]$OperationName = 'Azure-Aufruf'
    )

    $attempt = 0
    $delay = $InitialDelaySeconds

    while ($true) {
        $attempt++
        try {
            return & $ScriptBlock
        }
        catch {
            $isTransient = Test-TransientAzureError -ErrorRecord $_

            if (-not $isTransient -or $attempt -ge $MaxAttempts) {
                Write-Host "$OperationName fehlgeschlagen (Versuch $attempt/$MaxAttempts, transient=$isTransient): $($_.Exception.Message)"
                throw
            }

            Write-Host "$OperationName transient fehlgeschlagen (Versuch $attempt/$MaxAttempts), erneuter Versuch in $delay s: $($_.Exception.Message)"
            Start-Sleep -Seconds $delay
            $delay = $delay * 2
        }
    }
}

function Test-TransientAzureError {
    param(
        [Parameter(Mandatory)]$ErrorRecord
    )

    $message = $ErrorRecord.Exception.Message
    $statusCode = $null

    if ($ErrorRecord.Exception.PSObject.Properties.Match('Response').Count -gt 0 -and $ErrorRecord.Exception.Response) {
        $statusCode = [int]$ErrorRecord.Exception.Response.StatusCode
    }

    if ($statusCode -and ($statusCode -eq 429 -or $statusCode -eq 408 -or $statusCode -ge 500)) {
        return $true
    }

    $transientPatterns = @(
        'too many requests',
        'throttl',
        'timeout',
        'timed out',
        'temporarily unavailable',
        'service unavailable',
        'connection was closed',
        'connection reset'
    )

    foreach ($pattern in $transientPatterns) {
        if ($message -imatch [regex]::Escape($pattern)) {
            return $true
        }
    }

    return $false
}

function Test-AzResourceNotFoundError {
    param(
        [Parameter(Mandatory)]$ErrorRecord
    )

    $statusCode = $null
    if ($ErrorRecord.Exception.PSObject.Properties.Match('Response').Count -gt 0 -and $ErrorRecord.Exception.Response) {
        $statusCode = [int]$ErrorRecord.Exception.Response.StatusCode
    }
    if ($statusCode -eq 404) { return $true }

    $errorCode = $null
    if ($ErrorRecord.Exception.PSObject.Properties.Match('Body').Count -gt 0 -and $ErrorRecord.Exception.Body) {
        $errorCode = $ErrorRecord.Exception.Body.Code
    }
    if ($errorCode -in @('ResourceNotFound', 'NotFound', 'PublicIPAddressNotFound', 'NatGatewayNotFound')) { return $true }

    return ($ErrorRecord.Exception.Message -imatch 'was not found|could not be found|does not exist|ResourceNotFound')
}

function Get-AzResourceOrNull {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$OperationName = 'Azure-Lookup'
    )

    try {
        return Invoke-WithRetry -OperationName $OperationName -ScriptBlock $ScriptBlock
    }
    catch {
        if (Test-AzResourceNotFoundError -ErrorRecord $_) {
            return $null
        }
        throw
    }
}

Export-ModuleMember -Function Invoke-WithRetry, Test-TransientAzureError, Get-AzResourceOrNull, Test-AzResourceNotFoundError
