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

$lbName = "loadbalancer"
$lbIpAddress = "10.20.30.62"


Write-Host "Checking if resource group $resourceGroupName exists..."
$resourceGroup = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
if (-not $resourceGroup)
{
    Write-Host "Creating a resource group $resourceGroupName ..."
    New-AzResourceGroup -Name $resourceGroupName -Location $location
}
else
{
    Write-Host "Resource group $resourceGroupName already exists, using existing one."
}

Write-Host "Checking if web network security group exists..."
$webNsg = Get-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Name $webSubnetName -ErrorAction SilentlyContinue
if (-not $webNsg)
{
    Write-Host "Creating web network security group..."
    $webHttpRule = New-AzNetworkSecurityRuleConfig -Name "web" -Description "Allow HTTP" `
       -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix `
       Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 80,443

    $webAppRule = New-AzNetworkSecurityRuleConfig -Name "webapp" -Description "Allow app traffic from Load Balancer" `
       -Access Allow -Protocol Tcp -Direction Inbound -Priority 110 -SourceAddressPrefix `
       AzureLoadBalancer -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 8080

    $webNsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Location $location -Name `
       $webSubnetName -SecurityRules $webHttpRule,$webAppRule
}
else
{
    Write-Host "Web network security group already exists, checking for port 8080 rule..."

    $lbRule = $webNsg.SecurityRules | Where-Object { $_.Name -eq "webapp" }
    if (-not $lbRule) {
        Write-Host "Adding port 8080 rule for Load Balancer traffic..."
        $webNsg | Add-AzNetworkSecurityRuleConfig -Name "webapp" -Description "Allow app traffic from Load Balancer" `
           -Access Allow -Protocol Tcp -Direction Inbound -Priority 110 -SourceAddressPrefix `
           AzureLoadBalancer -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 8080

        $webNsg | Set-AzNetworkSecurityGroup
    } else {
        $needsUpdate = $false
        if ($lbRule.SourceAddressPrefix -ne "AzureLoadBalancer" -or
            $lbRule.DestinationPortRange -ne "8080" -or
            $lbRule.Protocol -ne "Tcp" -or
            $lbRule.Access -ne "Allow") {
            $needsUpdate = $true
        }

        if ($needsUpdate) {
            Write-Host "Updating existing port 8080 rule for Load Balancer traffic..."
            $webNsg | Set-AzNetworkSecurityRuleConfig -Name "webapp" -Description "Allow app traffic from Load Balancer" `
               -Access Allow -Protocol Tcp -Direction Inbound -Priority 110 -SourceAddressPrefix `
               AzureLoadBalancer -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 8080

            $webNsg | Set-AzNetworkSecurityGroup
        } else {
            Write-Host "Port 8080 rule for Load Balancer already exists and is correctly configured."
        }
    }
}

Write-Host "Checking if management network security group exists..."
$mngNsg = Get-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Name $mngSubnetName -ErrorAction SilentlyContinue
if (-not $mngNsg)
{
    Write-Host "Creating mngSubnet network security group..."
    $mngSshRule = New-AzNetworkSecurityRuleConfig -Name "ssh" -Description "Allow SSH" `
       -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix `
       Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22
    $mngNsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Location $location -Name `
       $mngSubnetName -SecurityRules $mngSshRule
}
else
{
    Write-Host "Management network security group already exists, using existing one."
}

Write-Host "Checking if virtual network exists..."
$virtualNetwork = Get-AzVirtualNetwork -ResourceGroupName $resourceGroupName -Name $virtualNetworkName -ErrorAction SilentlyContinue
if (-not $virtualNetwork)
{
    Write-Host "Creating a virtual network ..."
    $webSubnet = New-AzVirtualNetworkSubnetConfig -Name $webSubnetName -AddressPrefix $webSubnetIpRange -NetworkSecurityGroup $webNsg
    $mngSubnet = New-AzVirtualNetworkSubnetConfig -Name $mngSubnetName -AddressPrefix $mngSubnetIpRange -NetworkSecurityGroup $mngNsg
    $virtualNetwork = New-AzVirtualNetwork -Name $virtualNetworkName -ResourceGroupName $resourceGroupName -Location $location -AddressPrefix $vnetAddressPrefix -Subnet $webSubnet,$mngSubnet
}
else
{
    Write-Host "Virtual network already exists, using existing one."
}

$webSubnet = Get-AzVirtualNetworkSubnetConfig -Name $webSubnetName -VirtualNetwork $virtualNetwork
$mngSubnet = Get-AzVirtualNetworkSubnetConfig -Name $mngSubnetName -VirtualNetwork $virtualNetwork

Write-Host "Checking if SSH key exists..."
$sshKey = Get-AzSshKey -ResourceGroupName $resourceGroupName -Name $sshKeyName -ErrorAction SilentlyContinue
if (-not $sshKey)
{
    Write-Host "Creating a SSH key resource ..."
    New-AzSshKey -Name $sshKeyName -ResourceGroupName $resourceGroupName -PublicKey $sshKeyPublicKey
}
else
{
    Write-Host "SSH key already exists, using existing one."
}

Write-Host "Checking and creating web server VMs ..."

for (($zone = 1); ($zone -le 2); ($zone++)) {
    $vmName = "$webVmName-$zone"
    $existingVm = Get-AzVm -ResourceGroupName $resourceGroupName -Name $vmName -ErrorAction SilentlyContinue
    if (-not $existingVm)
    {
        Write-Host "Creating web server VM $vmName ..."
        New-AzVm `
       -ResourceGroupName $resourceGroupName `
       -Name $vmName `
       -Location $location `
       -image $vmImage `
       -size $vmSize `
       -SubnetName $webSubnetName `
       -VirtualNetworkName $virtualNetworkName `
       -SshKeyName $sshKeyName

        $existingExtension = Get-AzVMExtension -ResourceGroupName $resourceGroupName -VMName $vmName -Name 'CustomScript' -ErrorAction SilentlyContinue
        if (-not $existingExtension)
        {
            Write-Host "Installing custom script extension on $vmName ..."
            $Params = @{
                ResourceGroupName = $resourceGroupName
                VMName = $vmName
                Name = 'CustomScript'
                Publisher = 'Microsoft.Azure.Extensions'
                ExtensionType = 'CustomScript'
                TypeHandlerVersion = '2.1'
                Settings = @{ fileUris = @('https://raw.githubusercontent.com/mate-academy/azure_task_18_configure_load_balancing/main/install-app.sh'); commandToExecute = './install-app.sh' }
            }
            Set-AzVMExtension @Params
        }
        else
        {
            Write-Host "Custom script extension already exists on $vmName."
        }
    }
    else
    {
        Write-Host "Web server VM $vmName already exists, using existing one."
    }
}

Write-Host "Checking if public IP exists..."
$publicIP = Get-AzPublicIpAddress -ResourceGroupName $resourceGroupName -Name $jumpboxVmName -ErrorAction SilentlyContinue
if (-not $publicIP)
{
    Write-Host "Creating a public IP ..."
    $publicIP = New-AzPublicIpAddress -Name $jumpboxVmName -ResourceGroupName $resourceGroupName -Location $location -Sku Standard -AllocationMethod Static -DomainNameLabel $dnsLabel
}
else
{
    Write-Host "Public IP already exists, using existing one."
}

Write-Host "Checking if management VM exists..."
$existingJumpboxVm = Get-AzVm -ResourceGroupName $resourceGroupName -Name $jumpboxVmName -ErrorAction SilentlyContinue
if (-not $existingJumpboxVm)
{
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
}
else
{
    Write-Host "Management VM already exists, using existing one."
}

Write-Host "Checking if private DNS zone exists..."
$Zone = Get-AzPrivateDnsZone -ResourceGroupName $resourceGroupName -Name $privateDnsZoneName -ErrorAction SilentlyContinue
if (-not $Zone)
{
    Write-Host "Creating a private DNS zone ..."
    $Zone = New-AzPrivateDnsZone -Name $privateDnsZoneName -ResourceGroupName $resourceGroupName
}
else
{
    Write-Host "Private DNS zone already exists, using existing one."
}

Write-Host "Checking if virtual network link exists..."
$Link = Get-AzPrivateDnsVirtualNetworkLink -ZoneName $privateDnsZoneName -ResourceGroupName $resourceGroupName -Name $Zone.Name -ErrorAction SilentlyContinue
if (-not $Link)
{
    Write-Host "Creating virtual network link for DNS zone..."
    $Link = New-AzPrivateDnsVirtualNetworkLink -ZoneName $privateDnsZoneName -ResourceGroupName $resourceGroupName -Name $Zone.Name -VirtualNetworkId $virtualNetwork.Id -EnableRegistration
}
else
{
    Write-Host "Virtual network link already exists, using existing one."
}

Write-Host "Checking if DNS A record exists..."
$existingRecord = Get-AzPrivateDnsRecordSet -ResourceGroupName $resourceGroupName -ZoneName $privateDnsZoneName -Name "todo" -RecordType A -ErrorAction SilentlyContinue
if (-not $existingRecord) {
    Write-Host "Creating an A DNS record ..."
    $Records = @()
    $Records += New-AzPrivateDnsRecordConfig -IPv4Address $lbIpAddress
    New-AzPrivateDnsRecordSet -Name "todo" -RecordType A -ResourceGroupName $resourceGroupName -TTL 1800 -ZoneName $privateDnsZoneName -PrivateDnsRecords $Records
} else {
    $currentIpAddresses = $existingRecord.Records | ForEach-Object { $_.Ipv4Address }
    $needsUpdate = $false

    if ($currentIpAddresses.Count -ne 1 -or $currentIpAddresses[0] -ne $lbIpAddress) {
        $needsUpdate = $true
    }

    if ($needsUpdate) {
        Write-Host "DNS A record exists but points to different IP(s). Updating to point to $lbIpAddress ..."
        $existingRecord.Records.Clear()
        $existingRecord.Records.Add((New-AzPrivateDnsRecordConfig -IPv4Address $lbIpAddress))
        Set-AzPrivateDnsRecordSet -RecordSet $existingRecord
    } else {
        Write-Host "DNS A record already exists and points to the correct IP address."
    }
}

Write-Host "Checking if load balancer exists..."
$loadBalancer = Get-AzLoadBalancer -ResourceGroupName $resourceGroupName -Name $lbName -ErrorAction SilentlyContinue
if (-not $loadBalancer)
{
    Write-Host "Creating a load balancer ..."

    $feip = New-AzLoadBalancerFrontendIpConfig `
    -Name "myFrontEnd" `
    -PrivateIpAddress "10.20.30.62" `
    -Subnet $webSubnet

    $bepool = New-AzLoadBalancerBackendAddressPoolConfig -Name "myBackEndPool"

    $healthprobe = New-AzLoadBalancerProbeConfig `
    -Name "myHealthProbe" `
    -Protocol "tcp" `
    -Port "8080" `
    -IntervalInSeconds "360" `
    -ProbeCount "5"

    $rule = New-AzLoadBalancerRuleConfig `
    -Name "myHTTPRule" `
    -Protocol "tcp" `
    -FrontendPort "80" `
    -BackendPort "8080" `
    -IdleTimeoutInMinutes "15" `
    -FrontendIpConfiguration $feip `
    -BackendAddressPool $bepool `
    -Probe $healthprobe `
    -EnableTcpReset

    $loadBalancer = New-AzLoadBalancer `
    -Name $lbName `
    -ResourceGroupName $resourceGroupName `
    -Location $location `
    -Sku "Standard" `
    -FrontendIpConfiguration $feip `
    -BackendAddressPool $bepool `
    -LoadBalancingRule $rule `
    -Probe $healthprobe
}
else
{
    Write-Host "Load balancer already exists, using existing one."
}

$bepool = $loadBalancer.BackendAddressPools | Where-Object { $_.Name -eq "myBackEndPool" }

Write-Host "Checking and adding VMs to the backend pool"
$vms = Get-AzVm -ResourceGroupName $resourceGroupName | Where-Object { $_.Name.StartsWith($webVmName) }
foreach ($vm in $vms)
{
    $nic = Get-AzNetworkInterface -ResourceGroupName $resourceGroupName | Where-Object { $_.Id -eq $vm.NetworkProfile.NetworkInterfaces.Id }
    $ipCfg = $nic.IpConfigurations | Where-Object { $_.Primary }

    $alreadyInPool = $ipCfg.LoadBalancerBackendAddressPools | Where-Object { $_.Id -eq $bepool.Id }
    if (-not $alreadyInPool)
    {
        Write-Host "Adding VM $( $vm.Name ) to the backend pool"
        $ipCfg.LoadBalancerBackendAddressPools.Add($bepool)
        Set-AzNetworkInterface -NetworkInterface $nic
    }
    else
    {
        Write-Host "VM $( $vm.Name ) is already in the backend pool"
    }
}
