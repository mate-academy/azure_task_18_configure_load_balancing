############################################################
# Azure Task 18: Configure Load Balancing (clean start)
# Idempotent, uses Standard Public IP, Internal Standard LB
############################################################

$ErrorActionPreference = "Stop"

# ---------- Variables ----------
$location            = "uksouth"
$resourceGroupName   = "mate-azure-task-18"

$virtualNetworkName  = "todoapp"
$vnetAddressPrefix   = "10.20.30.0/24"
$webSubnetName       = "webservers"
$webSubnetIpRange    = "10.20.30.0/26"
$mngSubnetName       = "management"
$mngSubnetIpRange    = "10.20.30.128/26"

$sshKeyName          = "linuxboxsshkey"
$sshKeyPublicKeyPath = "~/.ssh/id_rsa.pub"

$vmImage             = "Ubuntu2204"
$vmSize              = "Standard_B1s"
$webVmName           = "webserver"
$jumpboxVmName       = "jumpbox"
$dnsLabel            = "matetask" + (Get-Random -Count 1)

$privateDnsZoneName  = "or.nottodo"

$lbName              = "loadbalancer"
$lbIpAddress         = "10.20.30.62"
$feName              = "$lbName-frontend"
$beName              = "$lbName-bepool"
$probeName           = "tcp8080"
$ruleName            = "http80to8080"

# ---------- Helpers ----------
function Ensure-ResourceGroup {
  param($Name, $Location)
  if (-not (Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue)) {
    Write-Host "Creating resource group $Name ..."
    New-AzResourceGroup -Name $Name -Location $Location | Out-Null
  } else { Write-Host "RG $Name exists — OK" }
}

function Ensure-SshKey {
  param($Name, $Rg, $PubKey)
  if (-not (Get-AzSshKey -ResourceGroupName $Rg -Name $Name -ErrorAction SilentlyContinue)) {
    Write-Host "Creating SSH key resource $Name ..."
    New-AzSshKey -Name $Name -ResourceGroupName $Rg -PublicKey $PubKey | Out-Null
  } else { Write-Host "SSH key $Name exists — OK" }
}

# ---------- RG ----------
Write-Host "Ensuring RG ..."
Ensure-ResourceGroup -Name $resourceGroupName -Location $location

# ---------- NSGs ----------
Write-Host "Ensuring NSGs ..."
# web NSG (Allow HTTP 80/443 + health probe 8080)
$webHttpRule = New-AzNetworkSecurityRuleConfig -Name "web" -Description "Allow HTTP" `
   -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 `
   -SourceAddressPrefix Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 80,443
$probeRule   = New-AzNetworkSecurityRuleConfig -Name "allow-probe-8080" -Description "Allow health probe from Azure Load Balancer" `
   -Access Allow -Protocol Tcp -Direction Inbound -Priority 110 `
   -SourceAddressPrefix AzureLoadBalancer -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 8080

$webNsg = Get-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Name $webSubnetName -ErrorAction SilentlyContinue
if (-not $webNsg) {
  $webNsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Location $location -Name $webSubnetName -SecurityRules $webHttpRule,$probeRule
} else {
  if (-not ($webNsg.SecurityRules | Where-Object Name -eq "web"))              { $webNsg.SecurityRules.Add($webHttpRule) | Out-Null }
  if (-not ($webNsg.SecurityRules | Where-Object Name -eq "allow-probe-8080")) { $webNsg.SecurityRules.Add($probeRule)   | Out-Null }
  Set-AzNetworkSecurityGroup -NetworkSecurityGroup $webNsg | Out-Null
}

# mng NSG (Allow SSH 22)
$mngSshRule = New-AzNetworkSecurityRuleConfig -Name "ssh" -Description "Allow SSH" `
   -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 `
   -SourceAddressPrefix Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22
$mngNsg = Get-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Name $mngSubnetName -ErrorAction SilentlyContinue
if (-not $mngNsg) {
  $mngNsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Location $location -Name $mngSubnetName -SecurityRules $mngSshRule
} else {
  if (-not ($mngNsg.SecurityRules | Where-Object Name -eq "ssh")) { $mngNsg.SecurityRules.Add($mngSshRule) | Out-Null }
  Set-AzNetworkSecurityGroup -NetworkSecurityGroup $mngNsg | Out-Null
}

# ---------- VNet & Subnets ----------
Write-Host "Ensuring VNet/Subnets ..."
$virtualNetwork = Get-AzVirtualNetwork -Name $virtualNetworkName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
if (-not $virtualNetwork) {
  $webSubnetCfg = New-AzVirtualNetworkSubnetConfig -Name $webSubnetName -AddressPrefix $webSubnetIpRange -NetworkSecurityGroup $webNsg
  $mngSubnetCfg = New-AzVirtualNetworkSubnetConfig -Name $mngSubnetName -AddressPrefix $mngSubnetIpRange -NetworkSecurityGroup $mngNsg
  $virtualNetwork = New-AzVirtualNetwork -Name $virtualNetworkName -ResourceGroupName $resourceGroupName -Location $location `
    -AddressPrefix $vnetAddressPrefix -Subnet $webSubnetCfg,$mngSubnetCfg
} else {
  $ws = $virtualNetwork.Subnets | Where-Object Name -eq $webSubnetName
  if (-not $ws) {
    Add-AzVirtualNetworkSubnetConfig -Name $webSubnetName -AddressPrefix $webSubnetIpRange -NetworkSecurityGroup $webNsg -VirtualNetwork $virtualNetwork | Out-Null
  } else { $ws.NetworkSecurityGroup = $webNsg }
  $ms = $virtualNetwork.Subnets | Where-Object Name -eq $mngSubnetName
  if (-not $ms) {
    Add-AzVirtualNetworkSubnetConfig -Name $mngSubnetName -AddressPrefix $mngSubnetIpRange -NetworkSecurityGroup $mngNsg -VirtualNetwork $virtualNetwork | Out-Null
  } else { $ms.NetworkSecurityGroup = $mngNsg }
  Set-AzVirtualNetwork -VirtualNetwork $virtualNetwork | Out-Null
}
$webSubnetId = (Get-AzVirtualNetworkSubnetConfig -Name $webSubnetName -VirtualNetwork $virtualNetwork).Id

# ---------- SSH Key Resource ----------
Write-Host "Ensuring SSH key resource ..."
$sshPub = Get-Content $sshKeyPublicKeyPath
Ensure-SshKey -Name $sshKeyName -Rg $resourceGroupName -PubKey $sshPub

# ---------- Credential once ----------
if (-not $cred) {
  $cred = Get-Credential -UserName 'azureuser' -Message 'Введи пароль для azureuser (використаємо для всіх ВМ)'
}

# ---------- Web VMs (1..2) + app install ----------
Write-Host "Ensuring Web VMs ..."
for ($zone = 1; $zone -le 2; $zone++) {
  $vmName = "$webVmName-$zone"

  if (-not (Get-AzVM -ResourceGroupName $resourceGroupName -Name $vmName -ErrorAction SilentlyContinue)) {
    New-AzVm `
      -ResourceGroupName $resourceGroupName `
      -Name $vmName `
      -Location $location `
      -Image $vmImage `
      -Size $vmSize `
      -SubnetName $webSubnetName `
      -VirtualNetworkName $virtualNetworkName `
      -SshKeyName $sshKeyName `
      -Credential $cred | Out-Null
  } else { Write-Host "VM $vmName exists — OK" }

  # Ensure web app is installed (port 8080)
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
  try {
    Set-AzVMExtension @Params | Out-Null
  }
  catch {
    Write-Warning ("Extension may already exist on {0}: {1}" -f $vmName, $_.Exception.Message)
  }
}

# ---------- Jumpbox Public IP (STANDARD) ----------
Write-Host "Ensuring Standard Public IP for jumpbox ..."
$publicIP = Get-AzPublicIpAddress -ResourceGroupName $resourceGroupName -Name $jumpboxVmName -ErrorAction SilentlyContinue
if (-not $publicIP) {
  $publicIP = New-AzPublicIpAddress -Name $jumpboxVmName -ResourceGroupName $resourceGroupName -Location $location `
    -Sku Standard -AllocationMethod Static -DomainNameLabel $dnsLabel
} else { Write-Host "Public IP $jumpboxVmName exists — OK" }

# ---------- Jumpbox VM ----------
Write-Host "Ensuring Jumpbox VM ..."
if (-not (Get-AzVM -ResourceGroupName $resourceGroupName -Name $jumpboxVmName -ErrorAction SilentlyContinue)) {
  New-AzVm `
    -ResourceGroupName $resourceGroupName `
    -Name $jumpboxVmName `
    -Location $location `
    -Image $vmImage `
    -Size $vmSize `
    -SubnetName $mngSubnetName `
    -VirtualNetworkName $virtualNetworkName `
    -SshKeyName $sshKeyName `
    -PublicIpAddressName $jumpboxVmName `
    -Credential $cred | Out-Null
} else {
  # ensure NIC has PIP attached (in case VM was created earlier without PIP)
  $jumpNic = Get-AzNetworkInterface -ResourceGroupName $resourceGroupName | Where-Object { $_.Name -like "$jumpboxVmName*" }
  if ($jumpNic) {
    $pip = Get-AzPublicIpAddress -ResourceGroupName $resourceGroupName -Name $jumpboxVmName
    if (-not $jumpNic.IpConfigurations[0].PublicIpAddress -or ($jumpNic.IpConfigurations[0].PublicIpAddress.Id -ne $pip.Id)) {
      $ipcfg = $jumpNic.IpConfigurations[0]
      $ipcfg.PublicIpAddress = $pip
      Set-AzNetworkInterface -NetworkInterface $jumpNic | Out-Null
      Write-Host "Attached Standard PIP to jumpbox NIC — OK"
    }
  }
  Write-Host "Jumpbox exists — OK"
}

# ---------- Private DNS zone + link ----------
Write-Host "Ensuring Private DNS zone + link ..."
$zone = Get-AzPrivateDnsZone -Name $privateDnsZoneName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
if (-not $zone) {
  $zone = New-AzPrivateDnsZone -Name $privateDnsZoneName -ResourceGroupName $resourceGroupName
}
if (-not (Get-AzPrivateDnsVirtualNetworkLink -ZoneName $privateDnsZoneName -ResourceGroupName $resourceGroupName -Name $zone.Name -ErrorAction SilentlyContinue)) {
  New-AzPrivateDnsVirtualNetworkLink -ZoneName $privateDnsZoneName -ResourceGroupName $resourceGroupName -Name $zone.Name -VirtualNetworkId $virtualNetwork.Id -EnableRegistration | Out-Null
}

# ---------- A record todo.or.nottodo -> LB FE IP ----------
Write-Host "Ensuring A-record todo.$privateDnsZoneName -> $lbIpAddress ..."
$rec = Get-AzPrivateDnsRecordSet -ResourceGroupName $resourceGroupName -ZoneName $privateDnsZoneName -Name "todo" -RecordType A -ErrorAction SilentlyContinue
if ($rec) {
  $rec.Records.Clear()
  $rec.Records.Add((New-AzPrivateDnsRecordConfig -IPv4Address $lbIpAddress))
  Set-AzPrivateDnsRecordSet -RecordSet $rec | Out-Null
} else {
  New-AzPrivateDnsRecordSet -Name "todo" -RecordType A -ResourceGroupName $resourceGroupName -TTL 1800 -ZoneName $privateDnsZoneName `
    -PrivateDnsRecords (New-AzPrivateDnsRecordConfig -IPv4Address $lbIpAddress) | Out-Null
}

# ---------- Internal Load Balancer ----------
Write-Host "Ensuring Internal Standard Load Balancer ..."
$lb = Get-AzLoadBalancer -ResourceGroupName $resourceGroupName -Name $lbName -ErrorAction SilentlyContinue
if (-not $lb) {
  $feCfg = New-AzLoadBalancerFrontendIpConfig -Name $feName -SubnetId $webSubnetId -PrivateIpAddress $lbIpAddress
  $beCfg = New-AzLoadBalancerBackendAddressPoolConfig -Name $beName
  $probe = New-AzLoadBalancerProbeConfig -Name $probeName -Protocol Tcp -Port 8080 -IntervalInSeconds 5 -ProbeCount 2
  $rule  = New-AzLoadBalancerRuleConfig -Name $ruleName -FrontendIpConfiguration $feCfg -BackendAddressPool $beCfg -Probe $probe `
           -Protocol Tcp -FrontendPort 80 -BackendPort 8080 -IdleTimeoutInMinutes 4 -EnableTcpReset
  $lb = New-AzLoadBalancer -ResourceGroupName $resourceGroupName -Name $lbName -Location $location -Sku Standard `
        -FrontendIpConfiguration $feCfg -BackendAddressPool $beCfg -Probe $probe -LoadBalancingRule $rule
} else { Write-Host "LB $lbName exists — OK" }

$bepool = Get-AzLoadBalancerBackendAddressPool -ResourceGroupName $resourceGroupName -LoadBalancerName $lbName -Name $beName

# ---------- Attach NICs to backend pool ----------
Write-Host "Ensuring NICs are in backend pool ..."
$webNics = Get-AzNetworkInterface -ResourceGroupName $resourceGroupName | Where-Object { $_.VirtualMachine -and ($_.Name -like "$webVmName*") }
foreach ($nic in $webNics) {
  $ipCfg = $nic.IpConfigurations | Where-Object { $_.Primary }
  if (-not ($ipCfg.LoadBalancerBackendAddressPools | Where-Object { $_.Id -eq $bepool.Id })) {
    $ipCfg.LoadBalancerBackendAddressPools.Add($bepool) | Out-Null
    Set-AzNetworkInterface -NetworkInterface $nic | Out-Null
    Write-Host "Added NIC $($nic.Name) to backend pool $($bepool.Name)"
  } else { Write-Host "NIC $($nic.Name) already in pool — OK" }
}

# ---------- Done ----------
Write-Host "All resources ensured. You can now connect to jumpbox and test:"
$jumpIp = (Get-AzPublicIpAddress -ResourceGroupName $resourceGroupName -Name $jumpboxVmName).IpAddress
Write-Host "Jumpbox IP: $jumpIp"
Write-Host "From jumpbox:"
Write-Host "  nslookup todo.$privateDnsZoneName"
Write-Host "  curl -I http://todo.$privateDnsZoneName/"
