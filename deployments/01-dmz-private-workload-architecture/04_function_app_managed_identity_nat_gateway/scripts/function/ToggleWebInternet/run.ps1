using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

try {
    Connect-AzAccount -Identity | Out-Null

    $ResourceGroupName = 'rg-<project>-<environment>-<region>'
    $VnetName          = 'vnet-<project>'
    $SubnetName        = 'snet-web'
    $NatGatewayName    = 'nat-<project>'

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

    $vnet   = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VnetName
    $subnet = $vnet.Subnets | Where-Object Name -eq $SubnetName

    if (-not $subnet) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body       = "Subnet '$SubnetName' wurde nicht gefunden."
        })
        return
    }

    switch ($State) {
        'on' {
            $nat = Get-AzNatGateway -ResourceGroupName $ResourceGroupName -Name $NatGatewayName
            if ($subnet.NatGateway -and $subnet.NatGateway.Id -eq $nat.Id) {
                $msg = 'Internetzugang war bereits aktiviert.'
            } else {
                $subnet.NatGateway = $nat
                $result = Set-AzVirtualNetwork -VirtualNetwork $vnet
                $msg = "Internetzugang aktiviert. ProvisioningState: $($result.ProvisioningState)"
            }
        }
        'off' {
            if (-not $subnet.NatGateway) {
                $msg = 'Internetzugang war bereits deaktiviert.'
            } else {
                $subnet.NatGateway = $null
                $result = Set-AzVirtualNetwork -VirtualNetwork $vnet
                $msg = "Internetzugang deaktiviert. ProvisioningState: $($result.ProvisioningState)"
            }
        }
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = $msg
    })

} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = "FEHLER: $($_.Exception.Message)"
    })
}
