$location = "polandcentral"
$resourceGroupName = "mate-azure-task-18"

$virtualNetworkName = "todoapp"
$vnetAddressPrefix = "10.20.30.0/24"
$webSubnetName = "webservers"
$webSubnetIpRange = "10.20.30.0/26"
$mngSubnetName = "management"
$mngSubnetIpRange = "10.20.30.128/26"

$sshKeyName = "linuxboxsshkey"
$sshKeyPublicKey = Get-Content "~/.ssh/id_rsa.pub"

$adminUsername = "naruto"
$adminPassword = ConvertTo-SecureString ("1111") -AsPlainText -Force
$vmCredential = New-Object System.Management.Automation.PSCredential ($adminUsername, $adminPassword)

$vmImage = "Ubuntu2204"
$vmSize = "Standard_D2s_v3"
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
   Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 80,443,8080
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
   -SshKeyName $sshKeyName `
   -Credential $vmCredential
   $Params = @{
      ResourceGroupName  = $resourceGroupName
      VMName             = $vmName
      Name               = 'CustomScript'
      Publisher          = 'Microsoft.Azure.Extensions'
      ExtensionType      = 'CustomScript'
      TypeHandlerVersion = '2.1'
      Settings          = @{fileUris = @('https://raw.githubusercontent.com/mate-academy/azure_task_17_work_with_dns/main/install-app.sh'); commandToExecute = './install-app.sh'}
   }
   Set-AzVMExtension @Params -Verbose
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
-PublicIpAddressName $publicIP `
-Credential $vmCredential


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
## Create load balancer frontend configuration and place in variable. ##
$lbip = @{
    Name = "lb-frontend"
    PrivateIpAddress = $lbIpAddress
    SubnetId = $webSubnetId
}
$feip = New-AzLoadBalancerFrontendIpConfig @lbip
## Create backend address pool configuration and place in variable. ##

$bepool = New-AzLoadBalancerBackendAddressPoolConfig -Name 'lb-backend-pool'
## Create the load balancer rule and place in variable. ##

## Create the health probe and place in variable. ##
$probe = @{
    Name = 'lb-health-probe'
    Protocol = 'tcp'
    Port = '8080'
    IntervalInSeconds = '360'
    ProbeCount = '5'
}
$healthprobe = New-AzLoadBalancerProbeConfig @probe

$lbrule = @{
    Name = 'lb-HTTP-rule'
    Protocol = 'tcp'
    FrontendPort = '80'
    BackendPort = '8080'
    IdleTimeoutInMinutes = '15'
    FrontendIpConfiguration = $feip
    BackendAddressPool = $bepool
}
$rule = New-AzLoadBalancerRuleConfig @lbrule -EnableTcpReset

## Create the load balancer resource. ##
$loadbalancer = @{
    ResourceGroupName = $resourceGroupName
    Name = $lbName
    Location = $location
    Sku = 'Standard'
    FrontendIpConfiguration = $feip
    BackendAddressPool = $bePool
    LoadBalancingRule = $rule
    Probe = $healthprobe
}
New-AzLoadBalancer @loadbalancer

Write-Host "Adding VMs to the backend pool"
$vms = Get-AzVm -ResourceGroupName $resourceGroupName | Where-Object {$_.Name.StartsWith($webVmName)}
foreach ($vm in $vms) {
   $nic = Get-AzNetworkInterface -ResourceGroupName $resourceGroupName | Where-Object {$_.Id -eq $vm.NetworkProfile.NetworkInterfaces.Id}    
   $ipCfg = $nic.IpConfigurations | Where-Object {$_.Primary} 
   $ipCfg.LoadBalancerBackendAddressPools.Add($bepool)
   Set-AzNetworkInterface -NetworkInterface $nic
}
