$location = "uksouth"
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
$vmSize = "Standard_B1s"
$webVmName = "webserver"
$jumpboxVmName = "jumpbox"
$dnsLabel = "matetask" + (Get-Random -Count 1)

$privateDnsZoneName = "or.nottodo"
$dnsRecordName = "todo"

$lbName = "loadbalancer"
$lbIpAddress = "10.20.30.62"


Write-Host "Creating a resource group $resourceGroupName ..."
if (-not (Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $resourceGroupName -Location $location
}

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
$publicIP = New-AzPublicIpAddress -Name $jumpboxVmName -ResourceGroupName $resourceGroupName -Location $location -Sku Basic -AllocationMethod Dynamic -DomainNameLabel $dnsLabel
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
# Check if dns zone already exists and create it if not
$zone = Get-AzPrivateDnsZone -Name $privateDnsZoneName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
if (-not $zone) {
    $zone = New-AzPrivateDnsZone -Name $privateDnsZoneName -ResourceGroupName $resourceGroupName
}
# Link zone to VNet
$linkName = "${privateDnsZoneName}-link"
$link = Get-AzPrivateDnsVirtualNetworkLink -ZoneName $privateDnsZoneName -ResourceGroupName $resourceGroupName -Name $linkName -ErrorAction SilentlyContinue
if (-not $link) {
    New-AzPrivateDnsVirtualNetworkLink -ZoneName $privateDnsZoneName -ResourceGroupName $resourceGroupName -Name $linkName -VirtualNetworkId $vnet.Id -EnableRegistration
}

Write-Host "Creating an A DNS record ..."
$record = Get-AzPrivateDnsRecordSet -Name $dnsRecordName -RecordType A -ZoneName $privateDnsZoneName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
if ($record) {
    $record.Records.Clear()
    Add-AzPrivateDnsRecordConfig -RecordSet $record -IPv4Address $lbIpAddress
    Set-AzPrivateDnsRecordSet -RecordSet $record
}
else {
    New-AzPrivateDnsRecordSet -Name $dnsRecordName -RecordType A -ZoneName $privateDnsZoneName -ResourceGroupName $resourceGroupName -Ttl 3600 -PrivateDnsRecords (New-AzPrivateDnsRecordConfig -IPv4Address $lbIpAddress)
}

# Prepare variables, required for creation and configuration of load balancer -
# you will need them to setup a load balancer 
$webSubnetId = (Get-AzVirtualNetworkSubnetConfig -Name $webSubnetName -VirtualNetwork $virtualNetwork).Id

# Write your code here ->
Write-Host "Creating a load balancer ..."
$net = @{
    Name = $virtualNetworkName
    ResourceGroupName = $resourceGroupName
}
$vnet = Get-AzVirtualNetwork @net

$lbip = New-AzLoadBalancerFrontendIpConfig `
    -Name "myFrontEnd" `
    -PrivateIpAddress $lbIpAddress `
    -PrivateIpAllocationMethod Static `
    -SubnetId $webSubnetId

$bepoolConfig = New-AzLoadBalancerBackendAddressPoolConfig -Name 'myBackEndPool'

$healthprobe = New-AzLoadBalancerProbeConfig -Name 'myHealthProbe' -Protocol Tcp -Port 8080 -IntervalInSeconds 15 -ProbeCount 2

$rule = New-AzLoadBalancingRuleConfig -Name 'myHTTPRule' `
    -FrontendIpConfiguration $lbip `
    -BackendAddressPool $bepoolConfig `
    -Probe $healthprobe `
    -Protocol Tcp -FrontendPort 80 -BackendPort 8080 -IdleTimeoutInMinutes 15 `
    -EnableTcpReset

$lb = New-AzLoadBalancer -ResourceGroupName $resourceGroupName `
    -Name $lbName -Location $location -Sku Standard `
    -FrontendIpConfiguration $lbip `
    -BackendAddressPool $bepoolConfig `
    -Probe $healthprobe `
    -LoadBalancingRule $rule

Write-Host "Load balancer created: $($lb.Name). Frontend IP: $lbIpAddress"

$backendPool = $lb.BackendAddressPools | Where-Object { $_.Name -eq 'myBackEndPool' }
if (-not $backendPool) {
    $backendPool = Get-AzLoadBalancerBackendAddressPool -ResourceGroupName $resourceGroupName -LoadBalancerName $lbName -Name 'myBackEndPool'
}

$webNsg = Get-AzNetworkSecurityGroup -Name $webSubnetName -ResourceGroupName $resourceGroupName
$exists = $webNsg.SecurityRules | Where-Object { $_.Name -eq 'allow-8080-from-vnet' }
if (-not $exists) {
    $allow8080 = New-AzNetworkSecurityRuleConfig -Name 'allow-8080-from-vnet' `
        -Description 'Allow LB/probe/data path from VNet to port 8080' `
        -Access Allow -Protocol Tcp -Direction Inbound -Priority 200 `
        -SourceAddressPrefix VirtualNetwork -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 8080
    $webNsg.SecurityRules += $allow8080
    Set-AzNetworkSecurityGroup -NetworkSecurityGroup $webNsg
    Write-Host "Added NSG rule allow-8080-from-vnet to web NSG"
}

Write-Host "Adding VMs to the backend pool"
$vms = Get-AzVm -ResourceGroupName $resourceGroupName | Where-Object { $_.Name -like "$webVmName-*" }
foreach ($vm in $vms) {

    $nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
    $nic = Get-AzNetworkInterface -ResourceId $nicId

    $ipCfg = $nic.IpConfigurations | Where-Object { $_.Primary -eq $true }
    if (-not $ipCfg) { $ipCfg = $nic.IpConfigurations[0] }

    if ($null -eq $ipCfg.LoadBalancerBackendAddressPools) {
        $ipCfg.LoadBalancerBackendAddressPools = @($backendPool)
    } else {
        if (-not ($ipCfg.LoadBalancerBackendAddressPools | Where-Object { $_.Id -eq $backendPool.Id })) {
            $ipCfg.LoadBalancerBackendAddressPools += $backendPool
        }
    }

    Set-AzNetworkInterface -NetworkInterface $nic
    Write-Host "Assigned NIC $($nic.Name) to backend pool"
}
