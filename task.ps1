# Parameters
$ResourceGroupName = "mate-azure-task-18"
$Location = "East US"
$VNetName = "web-vnet"
$WebSubnetName = "webservers"  # ЗМІНЕНО: "web" → "webservers"
$JumpboxSubnetName = "jumpbox"
$SshKeyName = "webserver-ssh-key"

# Create Resource Group
Write-Host "Creating Resource Group..."
$resourceGroup = New-AzResourceGroup -Name $ResourceGroupName -Location $Location
Write-Host "Created Resource Group: $ResourceGroupName"

# Create Virtual Network and Subnets
Write-Host "Creating Virtual Network..."
$webSubnet = New-AzVirtualNetworkSubnetConfig -Name $WebSubnetName -AddressPrefix "10.20.30.0/24"
$jumpboxSubnet = New-AzVirtualNetworkSubnetConfig -Name $JumpboxSubnetName -AddressPrefix "10.20.31.0/24"

$vnet = New-AzVirtualNetwork `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -Name $VNetName `
    -AddressPrefix "10.20.0.0/16" `
    -Subnet $webSubnet, $jumpboxSubnet

Write-Host "Virtual Network created"

# Create Public IP for Jumpbox
Write-Host "Creating Public IP for Jumpbox..."
$jumpboxPublicIp = New-AzPublicIpAddress `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -Name "jumpbox-ip" `
    -AllocationMethod "Static" `
    -Sku "Standard"

# Create NSG for Web Subnet
Write-Host "Creating Network Security Groups..."
$webNsg = New-AzNetworkSecurityGroup `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -Name "web-nsg"

$webNsg | Add-AzNetworkSecurityRuleConfig `
    -Name "allow-http" `
    -Description "Allow HTTP" `
    -Access Allow `
    -Protocol Tcp `
    -Direction Inbound `
    -Priority 100 `
    -SourceAddressPrefix * `
    -SourcePortRange * `
    -DestinationAddressPrefix * `
    -DestinationPortRange 80,8080 | Set-AzNetworkSecurityGroup

# Create NSG for Jumpbox
$jumpboxNsg = New-AzNetworkSecurityGroup `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -Name "jumpbox-nsg"

$jumpboxNsg | Add-AzNetworkSecurityRuleConfig `
    -Name "allow-ssh" `
    -Description "Allow SSH" `
    -Access Allow `
    -Protocol Tcp `
    -Direction Inbound `
    -Priority 100 `
    -SourceAddressPrefix * `
    -SourcePortRange * `
    -DestinationAddressPrefix * `
    -DestinationPortRange 22 | Set-AzNetworkSecurityGroup

# Create Web Servers
Write-Host "Creating Web Servers..."
$securePassword = ConvertTo-SecureString "Azure123456!" -AsPlainText -Force
$webServerCred = New-Object System.Management.Automation.PSCredential ("azureuser", $securePassword)

for ($i = 1; $i -le 2; $i++) {
    Write-Host "Creating webserver-$i"
    
    $nic = New-AzNetworkInterface `
        -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -Name "webserver-$i-nic" `
        -Subnet $vnet.Subnets[0] `
        -NetworkSecurityGroup $webNsg
    
    $vm = New-AzVM `
        -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -Name "webserver-$i" `
        -Image "Ubuntu2204" `
        -Size "Standard_B1s" `
        -Credential $webServerCred `
        -NetworkInterface $nic `
        -GenerateSshKey `
        -SshKeyName $SshKeyName
    
    Write-Host "Created webserver-$i"
}

# Create Jumpbox VM
Write-Host "Creating Jumpbox VM..."
$jumpboxNic = New-AzNetworkInterface `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -Name "jumpbox-nic" `
    -Subnet $vnet.Subnets[1] `
    -NetworkSecurityGroup $jumpboxNsg `
    -PublicIpAddress $jumpboxPublicIp

$jumpboxVm = New-AzVM `
    -ResourceGroupName $ResourceGroupName `
    -Location $Location `
    -Name "jumpbox" `
    -Image "Ubuntu2204" `
    -Size "Standard_B1s" `
    -Credential $webServerCred `
    -NetworkInterface $jumpboxNic `
    -GenerateSshKey `
    -SshKeyName $SshKeyName

Write-Host "Created jumpbox VM"

# Create Private DNS Zone
Write-Host "Creating Private DNS Zone..."
$dnsZone = New-AzPrivateDnsZone `
    -ResourceGroupName $ResourceGroupName `
    -Name "or.nottodo"

$dnsLink = New-AzPrivateDnsVirtualNetworkLink `
    -ResourceGroupName $ResourceGroupName `
    -ZoneName "or.nottodo" `
    -Name "vnet-link" `
    -VirtualNetworkId $vnet.Id

# Create DNS record
$recordConfig = New-AzPrivateDnsRecordConfig -IPv4Address "10.20.30.62"
New-AzPrivateDnsRecordSet `
    -ResourceGroupName $ResourceGroupName `
    -ZoneName "or.nottodo" `
    -Name "todo" `
    -RecordType A `
    -Ttl 3600 `
    -PrivateDnsRecords $recordConfig

Write-Host "DNS Zone created"

# Create Load Balancer
Write-Host "Creating Load Balancer..."
$frontendIP = New-AzLoadBalancerFrontendIpConfig `
    -Name "lb-frontend" `
    -PrivateIpAddress "10.20.30.62" `
    -Subnet $vnet.Subnets[0]

$backendPool = New-AzLoadBalancerBackendAddressPoolConfig -Name "webBackendPool"

$probe = New-AzLoadBalancerProbeConfig `
    -Name "webHealthProbe" `
    -Protocol Tcp `
    -Port 8080 `
    -IntervalInSeconds 15 `
    -ProbeCount 2

$lbrule = New-AzLoadBalancerRuleConfig `
    -Name "webLoadBalancerRule" `
    -FrontendIpConfiguration $frontendIP `
    -BackendAddressPool $backendPool `
    -Probe $probe `
    -Protocol Tcp `
    -FrontendPort 80 `
    -BackendPort 8080

$loadBalancer = New-AzLoadBalancer `
    -ResourceGroupName $ResourceGroupName `
    -Name "webLoadBalancer" `
    -Location $Location `
    -Sku "Standard" `
    -FrontendIpConfiguration $frontendIP `
    -BackendAddressPool $backendPool `
    -LoadBalancingRule $lbrule `
    -Probe $probe

Write-Host "Load Balancer created successfully"

# Add VMs to Load Balancer
Write-Host "Adding VMs to Load Balancer backend pool..."
$backendPool = Get-AzLoadBalancerBackendAddressPool `
    -ResourceGroupName $ResourceGroupName `
    -LoadBalancerName "webLoadBalancer" `
    -Name "webBackendPool"

for ($i = 1; $i -le 2; $i++) {
    $nic = Get-AzNetworkInterface -Name "webserver-$i-nic" -ResourceGroupName $ResourceGroupName
    $nic.IpConfigurations[0].LoadBalancerBackendAddressPools = @($backendPool)
    Set-AzNetworkInterface -NetworkInterface $nic
    Write-Host "Added webserver-$i to backend pool"
}

Write-Host "Deployment completed successfully!"
Write-Host "Load Balancer Frontend IP: 10.20.30.62"
Write-Host "DNS record: todo.or.nottodo -> 10.20.30.62"
Write-Host "Load Balancer deployed in subnet: webservers"