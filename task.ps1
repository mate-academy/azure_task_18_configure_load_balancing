$location = "polandcentral" # any region that is available in your Azure subscription
$resourceGroupName = "mate-azure-task-18"

$virtualNetworkName = "todoapp"
$vnetAddressPrefix = "10.20.30.0/24"
$webSubnetName = "webservers"
$webSubnetIpRange = "10.20.30.0/26"
$mngSubnetName = "management"
$mngSubnetIpRange = "10.20.30.128/26"

$sshKeyName = "linuxboxsshkey"
$sshKeyPublicKey = Get-Content "~/.ssh/id_rsa.pub"

$vmImage = "Ubuntu2204"
$vmSize = "Standard_F1as_v7"
$webVmName = "webserver"
$jumpboxVmName = "jumpbox"
$dnsLabel = "matetask" + (Get-Random -Count 1)

$privateDnsZoneName = "or.nottodo"

$lbName = "loadbalancer"
$lbIpAddress = "10.20.30.62"


Write-Host "Creating a resource group $resourceGroupName ..."
New-AzResourceGroup -Name $resourceGroupName -Location $location

Write-Host "Creating web network security group..."
$webHttpRule = New-AzNetworkSecurityRuleConfig -Name "web" -Description "Allow HTTP" `
   -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix `
   Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 80,443
$webNsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Location $location -Name `
   $webSubnetName -SecurityRules $webHttpRule

Write-Host "Creating mngSubnet network security group..."
$mngSshRule = New-AzNetworkSecurityRuleConfig -Name "ssh" -Description "Allow SSH" `
   -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix `
   Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22
$mngNsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Location $location -Name `
   $mngSubnetName -SecurityRules $mngSshRule

Write-Host "Creating a virtual network ..."
$webSubnet = New-AzVirtualNetworkSubnetConfig -Name $webSubnetName -AddressPrefix $webSubnetIpRange -NetworkSecurityGroup $webNsg
$mngSubnet = New-AzVirtualNetworkSubnetConfig -Name $mngSubnetName -AddressPrefix $mngSubnetIpRange -NetworkSecurityGroup $mngNsg
$virtualNetwork = New-AzVirtualNetwork -Name $virtualNetworkName -ResourceGroupName $resourceGroupName -Location $location -AddressPrefix $vnetAddressPrefix -Subnet $webSubnet,$mngSubnet

Write-Host "Creating a SSH key resource ..."
New-AzSshKey -Name $sshKeyName -ResourceGroupName $resourceGroupName -PublicKey $sshKeyPublicKey

Write-Host "Creating a web server VM ..."

for (($zone = 1); ($zone -le 2); ($zone++) ) {
   $vmName = "$webVmName-$zone"
   New-AzVm `
   -ResourceGroupName $resourceGroupName `
   -Name $vmName `
   -Location $location `
   -image $vmImage `
   -size $vmSize `
   -SubnetName $webSubnetName `
   -VirtualNetworkName $virtualNetworkName `
   -SshKeyName $sshKeyName 
   $Params = @{
      ResourceGroupName  = $resourceGroupName
      VMName             = $vmName
      Name               = 'CustomScript'
      Publisher          = 'Microsoft.Azure.Extensions'
      ExtensionType      = 'CustomScript'
      TypeHandlerVersion = '2.1'
      Settings          = @{fileUris = @('https://raw.githubusercontent.com/mate-academy/azure_task_18_configure_load_balancing/main/install-app.sh'); commandToExecute = './install-app.sh'}
   }
   Set-AzVMExtension @Params
}

Write-Host "Creating a public IP ..."
$publicIP = New-AzPublicIpAddress -Name $jumpboxVmName -ResourceGroupName $resourceGroupName -Location $location -Sku Standard -AllocationMethod Static -DomainNameLabel $dnsLabel
Write-Host "Creating a management VM ..."
New-AzVm `
-ResourceGroupName $resourceGroupName `
-Name $jumpboxVmName `
-Location $location `
-image $vmImage `
-size $vmSize `
-SubnetName $mngSubnetName `
-VirtualNetworkName $virtualNetworkName `
-SshKeyName $sshKeyName `
-PublicIpAddressName $jumpboxVmName


Write-Host "Creating a private DNS zone ..."
$Zone = New-AzPrivateDnsZone -Name $privateDnsZoneName -ResourceGroupName $resourceGroupName 
$Link = New-AzPrivateDnsVirtualNetworkLink -ZoneName $privateDnsZoneName -ResourceGroupName $resourceGroupName -Name $Zone.Name -VirtualNetworkId $virtualNetwork.Id -EnableRegistration


Write-Host "Creating an A DNS record ..."
$Records = @()
$Records += New-AzPrivateDnsRecordConfig -IPv4Address $lbIpAddress
New-AzPrivateDnsRecordSet -Name "todo" -RecordType A -ResourceGroupName $resourceGroupName -TTL 1800 -ZoneName $privateDnsZoneName -PrivateDnsRecords $Records

# Prepare variables, required for creation and configuration of load balancer - 
# you will need them to setup a load balancer 
$webSubnetId = (Get-AzVirtualNetworkSubnetConfig -Name $webSubnetName -VirtualNetwork $virtualNetwork).Id

# Write your code here -> 
Write-Host "Creating a load balancer ..."

$frontend = New-AzLoadBalancerFrontendIpConfig -Name "frontend" -PrivateIpAddress $lbIpAddress -SubnetId $webSubnetId
$bepool = New-AzLoadBalancerBackendAddressPoolConfig -Name "backendpool"
$probe = New-AzLoadBalancerProbeConfig -Name "healthprobe" -Protocol Tcp -Port 8080 -IntervalInSeconds 15 -ProbeCount 2
$rule = New-AzLoadBalancerRuleConfig -Name "httprule" -Protocol Tcp -FrontendPort 80 -BackendPort 8080 -FrontendIpConfiguration $frontend -BackendAddressPool $bepool -Probe $probe

New-AzLoadBalancer -Name $lbName -ResourceGroupName $resourceGroupName -Location $location -Sku Standard -FrontendIpConfiguration $frontend -BackendAddressPool $bepool -Probe $probe -LoadBalancingRule $rule


Write-Host "Adding VMs to the backend pool"
$vms = @(Get-AzVm -ResourceGroupName $resourceGroupName -ErrorAction Stop | Where-Object { $_.Name -in @("$webVmName-1", "$webVmName-2") })
if ($vms.Count -ne 2) {
   throw "Expected 2 webserver VMs, but found $($vms.Count)."
}

$backendAddresses = @()
foreach ($vm in $vms) {
   $nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
   if (-not $nicId) {
      throw "Cannot find NIC resource ID for $($vm.Name)."
   }
   $nic = Get-AzNetworkInterface -ResourceId $nicId -ErrorAction Stop
   $ipCfg = $nic.IpConfigurations | Where-Object { $_.Primary } | Select-Object -First 1
   if (-not $ipCfg) { $ipCfg = $nic.IpConfigurations | Select-Object -First 1 }
   if (-not $ipCfg.PrivateIpAddress) {
      throw "Cannot find private IP address for $($vm.Name)."
   }
   $backendAddresses += New-AzLoadBalancerBackendAddressConfig -Name $vm.Name -IpAddress $ipCfg.PrivateIpAddress -VirtualNetworkId $virtualNetwork.Id -ErrorAction Stop
   Write-Host "Backend target: $($vm.Name) -> $($ipCfg.PrivateIpAddress)"
}

$bepool = Get-AzLoadBalancerBackendAddressPool -ResourceGroupName $resourceGroupName -LoadBalancerName $lbName -Name "backendpool" -ErrorAction Stop
if ($null -eq $bepool.LoadBalancerBackendAddresses) {
   Set-AzLoadBalancerBackendAddressPool -ResourceGroupName $resourceGroupName -LoadBalancerName $lbName -Name "backendpool" -LoadBalancerBackendAddress $backendAddresses -Force -ErrorAction Stop
} else {
   $bepool.LoadBalancerBackendAddresses.Clear()
   foreach ($backendAddress in $backendAddresses) {
      $bepool.LoadBalancerBackendAddresses.Add($backendAddress)
   }
   Set-AzLoadBalancerBackendAddressPool -InputObject $bepool -Force -ErrorAction Stop
}

$bepool = Get-AzLoadBalancerBackendAddressPool -ResourceGroupName $resourceGroupName -LoadBalancerName $lbName -Name "backendpool" -ErrorAction Stop
if ($bepool.LoadBalancerBackendAddresses.Count -ne 2) {
   throw "Backend pool must contain 2 targets, but found $($bepool.LoadBalancerBackendAddresses.Count)."
}
Write-Host "Backend pool successfully configured with 2 targets."
