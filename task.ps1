$location = "denmarkeast"
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


# ============================================================
# RESOURCE GROUP
# ============================================================

Write-Host "Creating resource group $resourceGroupName ..."

New-AzResourceGroup `
   -Name $resourceGroupName `
   -Location $location


# ============================================================
# WEB NSG
# ============================================================

Write-Host "Creating web network security group ..."

$webHttpRule = New-AzNetworkSecurityRuleConfig `
   -Name "web" `
   -Description "Allow HTTP" `
   -Access Allow `
   -Protocol Tcp `
   -Direction Inbound `
   -Priority 100 `
   -SourceAddressPrefix Internet `
   -SourcePortRange * `
   -DestinationAddressPrefix * `
   -DestinationPortRange 80,443

$webNsg = New-AzNetworkSecurityGroup `
   -ResourceGroupName $resourceGroupName `
   -Location $location `
   -Name $webSubnetName `
   -SecurityRules $webHttpRule


# ============================================================
# MANAGEMENT NSG
# ============================================================

Write-Host "Creating management network security group ..."

$mngSshRule = New-AzNetworkSecurityRuleConfig `
   -Name "ssh" `
   -Description "Allow SSH" `
   -Access Allow `
   -Protocol Tcp `
   -Direction Inbound `
   -Priority 100 `
   -SourceAddressPrefix Internet `
   -SourcePortRange * `
   -DestinationAddressPrefix * `
   -DestinationPortRange 22

$mngNsg = New-AzNetworkSecurityGroup `
   -ResourceGroupName $resourceGroupName `
   -Location $location `
   -Name $mngSubnetName `
   -SecurityRules $mngSshRule


# ============================================================
# VIRTUAL NETWORK
# ============================================================

Write-Host "Creating virtual network ..."

$webSubnet = New-AzVirtualNetworkSubnetConfig `
   -Name $webSubnetName `
   -AddressPrefix $webSubnetIpRange `
   -NetworkSecurityGroup $webNsg

$mngSubnet = New-AzVirtualNetworkSubnetConfig `
   -Name $mngSubnetName `
   -AddressPrefix $mngSubnetIpRange `
   -NetworkSecurityGroup $mngNsg

$virtualNetwork = New-AzVirtualNetwork `
   -Name $virtualNetworkName `
   -ResourceGroupName $resourceGroupName `
   -Location $location `
   -AddressPrefix $vnetAddressPrefix `
   -Subnet $webSubnet,$mngSubnet


# ============================================================
# SSH KEY
# ============================================================

Write-Host "Creating SSH key resource ..."

New-AzSshKey `
   -Name $sshKeyName `
   -ResourceGroupName $resourceGroupName `
   -PublicKey $sshKeyPublicKey


# ============================================================
# AVAILABILITY SET
# ============================================================

Write-Host "Creating availability set ..."

$availabilitySet = New-AzAvailabilitySet `
   -ResourceGroupName $resourceGroupName `
   -Name "webservers-avset" `
   -Location $location `
   -Sku Aligned `
   -PlatformFaultDomainCount 2 `
   -PlatformUpdateDomainCount 5


# ============================================================
# WEB SERVERS
# ============================================================

Write-Host "Creating web server VMs ..."

for (($zone = 1); ($zone -le 2); ($zone++)) {

   $vmName = "$webVmName-$zone"

   Write-Host "Creating $vmName ..."

   New-AzVm `
      -ResourceGroupName $resourceGroupName `
      -Name $vmName `
      -Location $location `
      -Image $vmImage `
      -Size $vmSize `
      -SubnetName $webSubnetName `
      -VirtualNetworkName $virtualNetworkName `
      -SshKeyName $sshKeyName `
      -AvailabilitySetName "webservers-avset"

   $Params = @{
      ResourceGroupName  = $resourceGroupName
      VMName             = $vmName
      Name               = "CustomScript"
      Publisher          = "Microsoft.Azure.Extensions"
      ExtensionType      = "CustomScript"
      TypeHandlerVersion = "2.1"
      Settings           = @{
         fileUris = @(
            "https://raw.githubusercontent.com/mate-academy/azure_task_18_configure_load_balancing/main/install-app.sh"
         )
         commandToExecute = "./install-app.sh"
      }
   }

   Set-AzVMExtension @Params
}


# ============================================================
# PUBLIC IP FOR JUMPBOX
# ============================================================

Write-Host "Creating public IP ..."

$publicIP = New-AzPublicIpAddress `
   -Name $jumpboxVmName `
   -ResourceGroupName $resourceGroupName `
   -Location $location `
   -Sku Standard `
   -AllocationMethod Static `
   -DomainNameLabel $dnsLabel


# ============================================================
# JUMPBOX
# ============================================================

Write-Host "Creating management VM ..."

New-AzVm `
   -ResourceGroupName $resourceGroupName `
   -Name $jumpboxVmName `
   -Location $location `
   -Image $vmImage `
   -Size $vmSize `
   -SubnetName $mngSubnetName `
   -VirtualNetworkName $virtualNetworkName `
   -SshKeyName $sshKeyName `
   -PublicIpAddressName $jumpboxVmName


# ============================================================
# PRIVATE DNS ZONE
# ============================================================

Write-Host "Creating private DNS zone ..."

$Zone = New-AzPrivateDnsZone `
   -Name $privateDnsZoneName `
   -ResourceGroupName $resourceGroupName


# ============================================================
# DNS ZONE LINK
# ============================================================

Write-Host "Linking private DNS zone to virtual network ..."

$Link = New-AzPrivateDnsVirtualNetworkLink `
   -ZoneName $privateDnsZoneName `
   -ResourceGroupName $resourceGroupName `
   -Name $Zone.Name `
   -VirtualNetworkId $virtualNetwork.Id `
   -EnableRegistration


# ============================================================
# DNS RECORD
# ============================================================

Write-Host "Creating DNS A record todo.or.nottodo ..."

$Records = @()

$Records += New-AzPrivateDnsRecordConfig `
   -IPv4Address $lbIpAddress

New-AzPrivateDnsRecordSet `
   -Name "todo" `
   -RecordType A `
   -ResourceGroupName $resourceGroupName `
   -TTL 1800 `
   -ZoneName $privateDnsZoneName `
   -PrivateDnsRecords $Records


# ============================================================
# LOAD BALANCER VARIABLES
# ============================================================

$webSubnetId = (
   Get-AzVirtualNetworkSubnetConfig `
      -Name $webSubnetName `
      -VirtualNetwork $virtualNetwork
).Id


# ============================================================
# LOAD BALANCER FRONTEND
# ============================================================

Write-Host "Creating load balancer frontend ..."

$frontendIpConfig = New-AzLoadBalancerFrontendIpConfig `
   -Name "LoadBalancerFrontEnd" `
   -PrivateIpAddress $lbIpAddress `
   -SubnetId $webSubnetId


# ============================================================
# BACKEND POOL
# ============================================================

Write-Host "Creating backend pool ..."

$backendPool = New-AzLoadBalancerBackendAddressPoolConfig `
   -Name "BackendPool"


# ============================================================
# HEALTH PROBE
# ============================================================

Write-Host "Creating HTTP health probe ..."

$probe = New-AzLoadBalancerProbeConfig `
   -Name "HttpProbe" `
   -Protocol Http `
   -Port 8080 `
   -RequestPath "/"


# ============================================================
# LOAD BALANCING RULE
# ============================================================

Write-Host "Creating HTTP load balancing rule ..."

$rule = New-AzLoadBalancerRuleConfig `
   -Name "HttpRule" `
   -FrontendIpConfiguration $frontendIpConfig `
   -BackendAddressPool $backendPool `
   -Probe $probe `
   -Protocol Tcp `
   -FrontendPort 80 `
   -BackendPort 8080


# ============================================================
# LOAD BALANCER
# ============================================================

Write-Host "Creating load balancer ..."

$loadBalancer = New-AzLoadBalancer `
   -ResourceGroupName $resourceGroupName `
   -Name $lbName `
   -Location $location `
   -Sku Standard `
   -FrontendIpConfiguration $frontendIpConfig `
   -BackendAddressPool $backendPool `
   -Probe $probe `
   -LoadBalancingRule $rule


# ============================================================
# ADD WEB VMS TO BACKEND POOL
# ============================================================

Write-Host "Adding web VMs to backend pool ..."

$lb = Get-AzLoadBalancer `
   -ResourceGroupName $resourceGroupName `
   -Name $lbName

$bepool = $lb.BackendAddressPools |
   Where-Object {
      $_.Name -eq "BackendPool"
   }

if ($null -eq $bepool) {
   throw "BackendPool was not found in load balancer."
}

$vms = Get-AzVm `
   -ResourceGroupName $resourceGroupName |
   Where-Object {
      $_.Name -eq "$webVmName-1" -or
      $_.Name -eq "$webVmName-2"
   }

if ($vms.Count -ne 2) {
   throw "Expected 2 web server VMs, but found $($vms.Count)."
}

foreach ($vm in $vms) {

   Write-Host "Adding $($vm.Name) to backend pool ..."

   $nicName = (
      $vm.NetworkProfile.NetworkInterfaces[0].Id -split "/"
   )[-1]

   $nic = Get-AzNetworkInterface `
      -ResourceGroupName $resourceGroupName `
      -Name $nicName

   $ipConfig = $nic.IpConfigurations |
      Where-Object {
         $_.Primary -eq $true
      }

   if ($null -eq $ipConfig) {
      throw "Primary IP configuration was not found for $($vm.Name)."
   }

   $ipConfig.LoadBalancerBackendAddressPools.Clear()

   $ipConfig.LoadBalancerBackendAddressPools.Add($bepool)

   Set-AzNetworkInterface `
      -NetworkInterface $nic

   Write-Host "$($vm.Name) added successfully."
}


# ============================================================
# VERIFY BACKEND POOL
# ============================================================

Write-Host "Verifying backend pool ..."

$pool = Get-AzLoadBalancerBackendAddressPool `
   -ResourceGroupName $resourceGroupName `
   -LoadBalancerName $lbName `
   -Name "BackendPool"

$backendCount = @(
   $pool.BackendIpConfigurations
).Count

Write-Host "Backend targets: $backendCount"

if ($backendCount -ne 2) {
   throw "Backend pool should contain 2 backend targets, but contains $backendCount."
}

Write-Host "Load balancer configuration completed successfully."
Write-Host "Backend pool contains 2 targets."
Write-Host "DNS: todo.or.nottodo -> $lbIpAddress"