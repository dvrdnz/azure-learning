param($QueueItem, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

function Get-RequiredEnv {
    param([string]$Name)
    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "App Setting '$Name' ist nicht gesetzt."
    }
    return $value
}

$ResourceGroupName   = Get-RequiredEnv 'TOGGLEWEBINTERNET_RESOURCE_GROUP'
$VnetName            = Get-RequiredEnv 'TOGGLEWEBINTERNET_VNET_NAME'
$SubnetName          = Get-RequiredEnv 'TOGGLEWEBINTERNET_SUBNET_NAME'
$NatGatewayName      = Get-RequiredEnv 'TOGGLEWEBINTERNET_NAT_GATEWAY_NAME'
$PublicIpName        = Get-RequiredEnv 'TOGGLEWEBINTERNET_PUBLIC_IP_NAME'
$Location            = Get-RequiredEnv 'TOGGLEWEBINTERNET_LOCATION'
$LockContainerName   = 'locks'
$LockBlobName        = 'togglewebinternet.lock'
$MaxDequeueCount     = 5
$LeaseDurationSeconds = 60
$RenewIntervalSeconds = 25

$script:LastRenewedAt = $null

function Initialize-LockBlob {
    $ctx = Get-StorageContext
    $container = Invoke-WithRetry -OperationName 'Get-AzStorageContainer' -ScriptBlock {
        Get-AzStorageContainer -Name $LockContainerName -Context $ctx -ErrorAction SilentlyContinue
    }
    if (-not $container) {
        $container = Invoke-WithRetry -OperationName 'New-AzStorageContainer' -ScriptBlock {
            New-AzStorageContainer -Name $LockContainerName -Context $ctx -Permission Off
        }
    }

    $blob = Invoke-WithRetry -OperationName 'Get-AzStorageBlob' -ScriptBlock {
        Get-AzStorageBlob -Container $LockContainerName -Blob $LockBlobName -Context $ctx -ErrorAction SilentlyContinue
    }
    if (-not $blob) {
        $temp = Join-Path $env:TEMP 'togglewebinternet.lock'
        Set-Content -Path $temp -Value 'lock' -NoNewline -Encoding UTF8
        try {
            Invoke-WithRetry -OperationName 'Set-AzStorageBlobContent' -ScriptBlock {
                Set-AzStorageBlobContent -Container $LockContainerName -Blob $LockBlobName -File $temp -Context $ctx | Out-Null
            }
        }
        finally {
            Remove-Item -Path $temp -ErrorAction SilentlyContinue
        }
    }
}

function Enter-Lock {
    Initialize-LockBlob
    $ctx = Get-StorageContext
    $blob = Get-AzStorageBlob -Container $LockContainerName -Blob $LockBlobName -Context $ctx

    $leaseClient = New-Object Azure.Storage.Blobs.Specialized.BlobLeaseClient -ArgumentList $blob.BlobBaseClient

    try {
        $leaseClient.Acquire((New-TimeSpan -Seconds $LeaseDurationSeconds)) | Out-Null
    }
    catch {
        $ex = $_.Exception
        $statusCode = $null
        if ($ex.PSObject.Properties.Match('Status').Count -gt 0) { $statusCode = $ex.Status }
        $errorCode = $null
        if ($ex.PSObject.Properties.Match('ErrorCode').Count -gt 0) { $errorCode = $ex.ErrorCode }

        if ($statusCode -eq 409 -or $errorCode -eq 'LeaseAlreadyPresent') {
            throw 'LOCK_BEREITS_BELEGT'
        }
        throw
    }

    $script:LastRenewedAt = Get-Date
    return $leaseClient
}

function Confirm-LockRenewal {
    param($LeaseClient)

    if (-not $LeaseClient) { return }
    if (((Get-Date) - $script:LastRenewedAt).TotalSeconds -lt $RenewIntervalSeconds) { return }

    try {
        $LeaseClient.Renew() | Out-Null
        $script:LastRenewedAt = Get-Date
    }
    catch {
        throw 'LOCK_RENEW_FEHLGESCHLAGEN'
    }
}

function Exit-Lock {
    param($LeaseClient)

    if (-not $LeaseClient) { return }

    try {
        $LeaseClient.Release() | Out-Null
    }
    catch {
    }
}

function Get-SubnetObject {
    $vnet = Invoke-WithRetry -OperationName 'Get-AzVirtualNetwork' -ScriptBlock {
        Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VnetName
    }
    $subnet = $vnet.Subnets | Where-Object Name -eq $SubnetName
    if (-not $subnet) { throw "Subnet '$SubnetName' wurde nicht gefunden." }
    return $subnet
}

function Initialize-PublicIp {
    param($LeaseClient)

    $pip = Get-AzResourceOrNull -OperationName 'Get-AzPublicIpAddress' -ScriptBlock {
        Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $PublicIpName -ErrorAction Stop
    }
    if (-not $pip) {
        Confirm-LockRenewal -LeaseClient $LeaseClient
        $pip = Invoke-WithRetry -OperationName 'New-AzPublicIpAddress' -ScriptBlock {
            New-AzPublicIpAddress `
                -ResourceGroupName $ResourceGroupName `
                -Name $PublicIpName `
                -Location $Location `
                -Sku Standard `
                -AllocationMethod Static `
                -Tier Regional
        }
    }
    return $pip
}

function Initialize-NatGateway {
    param($LeaseClient)

    $nat = Get-AzResourceOrNull -OperationName 'Get-AzNatGateway' -ScriptBlock {
        Get-AzNatGateway -ResourceGroupName $ResourceGroupName -Name $NatGatewayName -ErrorAction Stop
    }
    if (-not $nat) {
        $pip = Initialize-PublicIp -LeaseClient $LeaseClient
        Confirm-LockRenewal -LeaseClient $LeaseClient
        $nat = Invoke-WithRetry -OperationName 'New-AzNatGateway' -ScriptBlock {
            New-AzNatGateway `
                -ResourceGroupName $ResourceGroupName `
                -Name $NatGatewayName `
                -Location $Location `
                -Sku Standard `
                -PublicIpAddress $pip
        }
    }
    return $nat
}

function Add-NatToSubnet {
    param($Nat)

    $vnet = Invoke-WithRetry -OperationName 'Get-AzVirtualNetwork' -ScriptBlock {
        Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VnetName
    }
    $subnet = $vnet.Subnets | Where-Object Name -eq $SubnetName
    if (-not $subnet) { throw "Subnet '$SubnetName' wurde nicht gefunden." }

    if ($subnet.NatGateway -and $subnet.NatGateway.Id -eq $Nat.Id) {
        return
    }

    $subnet.NatGateway = $Nat
    Invoke-WithRetry -OperationName 'Set-AzVirtualNetwork' -ScriptBlock {
        Set-AzVirtualNetwork -VirtualNetwork $vnet | Out-Null
    }
}

function Remove-NatFromSubnet {
    $vnet = Invoke-WithRetry -OperationName 'Get-AzVirtualNetwork' -ScriptBlock {
        Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VnetName
    }
    $subnet = $vnet.Subnets | Where-Object Name -eq $SubnetName
    if (-not $subnet) { throw "Subnet '$SubnetName' wurde nicht gefunden." }

    if (-not $subnet.NatGateway) {
        return
    }

    $subnet.NatGateway = $null
    Invoke-WithRetry -OperationName 'Set-AzVirtualNetwork' -ScriptBlock {
        Set-AzVirtualNetwork -VirtualNetwork $vnet | Out-Null
    }
}

function Wait-SubnetNatState {
    param(
        [string]$ExpectedNatId,
        $LeaseClient,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        Start-Sleep -Seconds 5
        Confirm-LockRenewal -LeaseClient $LeaseClient
        $subnet = Get-SubnetObject
        $current = if ($subnet.NatGateway) { $subnet.NatGateway.Id } else { $null }

        if ($ExpectedNatId) {
            if ($current -eq $ExpectedNatId) { return }
        }
        else {
            if (-not $current) { return }
        }
    } while ((Get-Date) -lt $deadline)

    throw "Timeout beim Warten auf den gewünschten Subnetz-Zustand."
}

function Remove-NatGatewayIfExists {
    param($LeaseClient)

    $nat = Get-AzResourceOrNull -OperationName 'Get-AzNatGateway' -ScriptBlock {
        Get-AzNatGateway -ResourceGroupName $ResourceGroupName -Name $NatGatewayName -ErrorAction Stop
    }
    if ($nat) {
        Confirm-LockRenewal -LeaseClient $LeaseClient
        Invoke-WithRetry -OperationName 'Remove-AzNatGateway' -ScriptBlock {
            Remove-AzNatGateway -ResourceGroupName $ResourceGroupName -Name $NatGatewayName -Force
        }
    }
}

function Remove-PublicIpIfExists {
    param($LeaseClient)

    $pip = Get-AzResourceOrNull -OperationName 'Get-AzPublicIpAddress' -ScriptBlock {
        Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $PublicIpName -ErrorAction Stop
    }
    if ($pip) {
        Confirm-LockRenewal -LeaseClient $LeaseClient
        Invoke-WithRetry -OperationName 'Remove-AzPublicIpAddress' -ScriptBlock {
            Remove-AzPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $PublicIpName -Force
        }
    }
}

# Queue-Input robust behandeln
if ($QueueItem -is [byte[]]) {
    $QueueItem = [System.Text.Encoding]::UTF8.GetString($QueueItem)
}

if ($QueueItem -is [string]) {
    $QueueItem = $QueueItem.Trim([char]0xFEFF).Trim()
    try {
        $job = $QueueItem | ConvertFrom-Json
    }
    catch {
        $decodedBytes = [System.Convert]::FromBase64String($QueueItem)
        $decodedText  = [System.Text.Encoding]::UTF8.GetString($decodedBytes)
        $job = $decodedText | ConvertFrom-Json
    }
}
else {
    $job = $QueueItem
}

$OperationId  = $job.operationId
$State        = $job.state
$RequestedAt  = $job.requestedAt
$DequeueCount = [int]$TriggerMetadata.DequeueCount

$leaseClient = $null

try {
    Invoke-WithRetry -OperationName 'Connect-AzAccount(Identity)' -ScriptBlock {
        Connect-AzAccount -Identity | Out-Null
    }

    try {
        $leaseClient = Enter-Lock
    }
    catch {
        if ($_.Exception.Message -eq 'LOCK_BEREITS_BELEGT' -and $DequeueCount -ge $MaxDequeueCount) {
            Set-OperationStatus -OperationId $OperationId -State $State -Status 'Failed' `
                -Message 'Lock war dauerhaft belegt; Auftrag nach mehreren Versuchen verworfen.' -RequestedAt $RequestedAt
        }
        throw
    }

    Set-OperationStatus -OperationId $OperationId -State $State -Status 'Running' -RequestedAt $RequestedAt

    if ($State -eq 'on') {
        $nat = Initialize-NatGateway -LeaseClient $leaseClient

        try {
            Add-NatToSubnet -Nat $nat
            Confirm-LockRenewal -LeaseClient $leaseClient
            Wait-SubnetNatState -ExpectedNatId $nat.Id -LeaseClient $leaseClient
            Set-OperationStatus -OperationId $OperationId -State $State -Status 'Succeeded' `
                -Message 'Internetzugang aktiviert.' -RequestedAt $RequestedAt
        }
        catch {
            try { Remove-NatFromSubnet } catch { }
            try { Remove-NatGatewayIfExists -LeaseClient $leaseClient } catch { }
            try { Remove-PublicIpIfExists -LeaseClient $leaseClient } catch { }
            throw
        }
    }
    else {
        Remove-NatFromSubnet
        Confirm-LockRenewal -LeaseClient $leaseClient
        Wait-SubnetNatState -ExpectedNatId $null -LeaseClient $leaseClient

        $cleanupErrors = @()
        try { Remove-NatGatewayIfExists -LeaseClient $leaseClient } catch { $cleanupErrors += $_.Exception.Message }
        try { Remove-PublicIpIfExists -LeaseClient $leaseClient } catch { $cleanupErrors += $_.Exception.Message }

        if ($cleanupErrors.Count -gt 0) {
            Set-OperationStatus -OperationId $OperationId -State $State -Status 'CleanupPending' `
                -Message ($cleanupErrors -join ' | ') -RequestedAt $RequestedAt
        }
        else {
            Set-OperationStatus -OperationId $OperationId -State $State -Status 'Succeeded' `
                -Message 'Internetzugang deaktiviert.' -RequestedAt $RequestedAt
        }
    }
}
catch {
    if ($_.Exception.Message -eq 'LOCK_RENEW_FEHLGESCHLAGEN') {
        Set-OperationStatus -OperationId $OperationId -State $State -Status 'Failed' `
            -Message 'Lock-Erneuerung fehlgeschlagen; Vorgang abgebrochen, um Ressourcen nicht ohne gültigen Lock zu verändern.' -RequestedAt $RequestedAt
    }
    elseif ($_.Exception.Message -ne 'LOCK_BEREITS_BELEGT') {
        Set-OperationStatus -OperationId $OperationId -State $State -Status 'Failed' `
            -Message $_.Exception.Message -RequestedAt $RequestedAt
    }
    throw
}
finally {
    Exit-Lock -LeaseClient $leaseClient
}
