$location = "uksouth"
$resourceGroupName = "mate-resources"

$virtualNetworkName = "todoapp"
$vnetAddressPrefix = "10.20.30.0/24"
$webSubnetName = "webservers"
$webSubnetIpRange = "10.20.30.0/26"
$mngSubnetName = "management"
$mngSubnetIpRange = "10.20.30.128/26"

$sshKeyName = "linuxboxsshkey"
$sshKeyPublicKey = Get-Content "~/.ssh/id_rsa.pub"

$vmImage = "Ubuntu2204"
$vmSize = "Standard_B1s"
$webVmName = "webserver"
$jumpboxVmName = "jumpbox"
$dnsLabel = "matetask" + (Get-Random -Count 1)

$privateDnsZoneName = "or.nottodo"

$lbName = "loadbalancer"
$lbIpAddress = "10.20.30.62"

# Create resource group
Write-Host "Creating resource group $resourceGroupName ..."
New-AzResourceGroup -Name $resourceGroupName -Location $location

# Create NSGs
Write-Host "Creating web NSG..."
$webHttpRule = New-AzNetworkSecurityRuleConfig -Name "web" -Description "Allow HTTP" `
   -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix Internet `
   -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 80,443
$webNsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Location $location `
   -Name $webSubnetName -SecurityRules $webHttpRule

Write-Host "Creating management NSG..."
$mngSshRule = New-AzNetworkSecurityRuleConfig -Name "ssh" -Description "Allow SSH" `
   -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix Internet `
   -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22
$mngNsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Location $location `
   -Name $mngSubnetName -SecurityRules $mngSshRule

# Create Virtual Network and Subnets
Write-Host "Creating virtual network ..."
$webSubnet = New-AzVirtualNetworkSubnetConfig -Name $webSubnetName -AddressPrefix $webSubnetIpRange -NetworkSecurityGroup $webNsg
$mngSubnet = New-AzVirtualNetworkSubnetConfig -Name $mngSubnetName -AddressPrefix $mngSubnetIpRange -NetworkSecurityGroup $mngNsg
$virtualNetwork = New-AzVirtualNetwork -Name $virtualNetworkName -ResourceGroupName $resourceGroupName `
   -Location $location -AddressPrefix $vnetAddressPrefix -Subnet $webSubnet,$mngSubnet

# Create SSH key
Write-Host "Creating SSH key ..."
New-AzSshKey -Name $sshKeyName -ResourceGroupName $resourceGroupName -PublicKey $sshKeyPublicKey

# Create Web VMs
Write-Host "Creating web VMs ..."
for (($zone = 1); ($zone -le 2); ($zone++) ) {
    $vmName = "$webVmName-$zone"
    New-AzVm -ResourceGroupName $resourceGroupName -Name $vmName -Location $location `
       -Image $vmImage -Size $vmSize -SubnetName $webSubnetName -VirtualNetworkName $virtualNetworkName `
       -SshKeyName $sshKeyName

    $Params = @{
        ResourceGroupName  = $resourceGroupName
        VMName             = $vmName
        Name               = 'CustomScript'
        Publisher          = 'Microsoft.Azure.Extensions'
        ExtensionType      = 'CustomScript'
        TypeHandlerVersion = '2.1'
        Settings           = @{
            fileUris = @('https://raw.githubusercontent.com/mate-academy/azure_task_18_configure_load_balancing/main/install-app.sh')
            commandToExecute = './install-app.sh'
        }
    }
    Set-AzVMExtension @Params
}

# Create Public IP for Jumpbox
Write-Host "Creating public IP for jumpbox ..."
$publicIP = New-AzPublicIpAddress -Name $jumpboxVmName -ResourceGroupName $resourceGroupName `
    -Location $location -Sku Basic -AllocationMethod Dynamic -DomainNameLabel $dnsLabel

# Create Jumpbox VM
Write-Host "Creating jumpbox VM ..."
New-AzVm -ResourceGroupName $resourceGroupName -Name $jumpboxVmName -Location $location `
   -Image $vmImage -Size $vmSize -SubnetName $mngSubnetName -VirtualNetworkName $virtualNetworkName `
   -SshKeyName $sshKeyName -PublicIpAddressName $jumpboxVmName

# Create Private DNS Zone
Write-Host "Creating private DNS zone ..."
$zone = New-AzPrivateDnsZone -Name $privateDnsZoneName -ResourceGroupName $resourceGroupName
$link = New-AzPrivateDnsVirtualNetworkLink -ZoneName $privateDnsZoneName -ResourceGroupName $resourceGroupName `
    -Name $zone.Name -VirtualNetworkId $virtualNetwork.Id -EnableRegistration

# Create A record for LB
Write-Host "Creating A record for 'todo' ..."
$records = @()
$records += New-AzPrivateDnsRecordConfig -IPv4Address $lbIpAddress
New-AzPrivateDnsRecordSet -Name "todo" -RecordType A -ResourceGroupName $resourceGroupName `
    -TTL 1800 -ZoneName $privateDnsZoneName -PrivateDnsRecords $records

# -------------------
# Private Load Balancer
# -------------------
Write-Host "Creating private Load Balancer ..."

# Get web subnet ID
$vnet = Get-AzVirtualNetwork -Name $virtualNetworkName -ResourceGroupName $resourceGroupName
$webSubnetId = ($vnet.Subnets | Where-Object {$_.Name -eq $webSubnetName}).Id

# Backend pool
$backendPool = New-AzLoadBalancerBackendAddressPoolConfig -Name "webBackendPool"

# Frontend IP
$frontendIP = New-AzLoadBalancerFrontendIpConfig -Name "webFrontEnd" `
    -PrivateIpAddress $lbIpAddress -SubnetId $webSubnetId

# Health probe
$healthProbe = New-AzLoadBalancerProbeConfig -Name "webHealthProbe" -Protocol Tcp `
    -Port 8080 -IntervalInSeconds 15 -ProbeCount 2

# Load balancing rule
$lbRule = New-AzLoadBalancerRuleConfig -Name "httpRule" `
    -FrontendIpConfiguration $frontendIP `
    -BackendAddressPool $backendPool `
    -Protocol Tcp -FrontendPort 80 -BackendPort 8080 `
    -Probe $healthProbe -IdleTimeoutInMinutes 15 -EnableFloatingIP $false

# Create the Load Balancer
$loadBalancer = New-AzLoadBalancer -ResourceGroupName $resourceGroupName -Name $lbName -Location $location `
    -Sku Standard -FrontendIpConfiguration $frontendIP -BackendAddressPool $backendPool `
    -Probe $healthProbe -LoadBalancingRule $lbRule

# Add web VMs to backend pool
Write-Host "Adding web VMs to backend pool ..."
$vms = Get-AzVm -ResourceGroupName $resourceGroupName | Where-Object {$_.Name -like "$webVmName*"}
foreach ($vm in $vms) {
    $nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
    $nicName = ($nicId -split '/')[8] # Extract NIC name from ID
    $nic = Get-AzNetworkInterface -ResourceGroupName $resourceGroupName -Name $nicName
    $nic.IpConfigurations[0].LoadBalancerBackendAddressPools.Add($backendPool)
    Set-AzNetworkInterface -NetworkInterface $nic
}

Write-Host "Deployment complete!"