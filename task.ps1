$location =                             "uksouth"
$resourceGroupName =                    "mate-azure-task-18"

# Network Settings
$virtualNetworkName =                   "todoapp"
$vnetAddressPrefix =                    "10.20.30.0/24"

$webSubnetName =                        "webservers"
$webSubnetIpRange =                     "10.20.30.0/26"

$mngSubnetName =                        "management"
$mngSubnetIpRange =                     "10.20.30.128/26"

# SSH settings
$sshKeyName =                           "linuxboxsshkey"
$sshKeyPublicKey =                      Get-Content "~/.ssh/id_rsa.pub"

# Domain settings
$privateDnsZoneName =                   "or.nottodo"
$webSetSubdomain =                      "todo"

# Boot Diagnostic Storage Account settings
$bootStorageAccName =                   "bootdiagnosstorageacc"
$bootStSkuName =                        "Standard_LRS"
$bootStKind =                           "StorageV2"
$bootStAccessTier =                     "Hot"
$bootStMinimumTlsVersion =              "TLS1_0"

# VM settings
$vmSize =                               "Standard_B1s"
$webVmName =                            "webserver"
$jumpboxVmName =                        "jumpbox"
$dnsLabel =                             "matetask" + (Get-Random -Count 1)

# OS settings:
$osUser =                               "yegor"
$osUserPassword =                       "P@ssw0rd1234"
  $SecuredPassword = ConvertTo-SecureString `
    $osUserPassword -AsPlainText -Force
  $cred = New-Object System.Management.Automation.PSCredential `
    ($osUser, $SecuredPassword)
$osPublisherName =                      "Canonical"
$osOffer =                              "0001-com-ubuntu-server-jammy"
$osSku =                                "22_04-lts-gen2"
$osVersion =                            "latest"
$osDiskSizeGB =                         64
$osDiskType =                           "Premium_LRS"

# Load Balancer settings
$lbName =                               "loadbalancer"
  # Load Balancer web VMs rule settings
  $lbFeName =                           "Lb_Fe_WebServer"
  $lbFePort =                           "80"
  $lbFeIpAddress =                      "10.20.30.62"
  $lbBeName =                           "Lb_Be_Webserver"
  $lbBePort =                           "8080"
  $lbRuleName =                         "LoadBalancer_WebServerVMs_assign_ip_${lbFeIpAddress}"
  $lbHealthProbeName =                  "LoadBalancer_WebServerVMs_probe"


Write-Host "Creating a resource group $resourceGroupName ..."
New-AzResourceGroup `
  -Name                                 $resourceGroupName `
  -Location                             $location

Write-Host "Creating web network security group..."
$webHttpRule = New-AzNetworkSecurityRuleConfig `
  -Name                                 "web" `
  -Description                          "Allow HTTP" `
  -Access                               "Allow" `
  -Protocol                             "Tcp" `
  -Direction                            "Inbound" `
  -Priority                             100 `
  -SourceAddressPrefix                  "Internet" `
  -SourcePortRange                      * `
  -DestinationAddressPrefix             * `
  -DestinationPortRange                 80,443
$webNsg = New-AzNetworkSecurityGroup `
  -ResourceGroupName                    $resourceGroupName `
  -Location                             $location `
  -Name                                 $webSubnetName `
  -SecurityRules                        $webHttpRule

Write-Host "Creating mngSubnet network security group..."
$mngSshRule = New-AzNetworkSecurityRuleConfig `
  -Name                                 "ssh" `
  -Description                          "Allow SSH" `
  -Access                               "Allow" `
  -Protocol                             "Tcp" `
  -Direction                            "Inbound" `
  -Priority                             100 `
  -SourceAddressPrefix                  "Internet" `
  -SourcePortRange                      * `
  -DestinationAddressPrefix             * `
  -DestinationPortRange                 22
$mngNsg = New-AzNetworkSecurityGroup `
  -ResourceGroupName                    $resourceGroupName `
  -Location                             $location `
  -Name                                 $mngSubnetName `
  -SecurityRules                        $mngSshRule

Write-Host "Creating a virtual network ..."
$webSubnet = New-AzVirtualNetworkSubnetConfig `
  -Name                                 $webSubnetName `
  -AddressPrefix                        $webSubnetIpRange `
  -NetworkSecurityGroup                 $webNsg
$mngSubnet = New-AzVirtualNetworkSubnetConfig `
  -Name                                 $mngSubnetName `
  -AddressPrefix                        $mngSubnetIpRange `
  -NetworkSecurityGroup                 $mngNsg
$vnetObj = New-AzVirtualNetwork `
  -Name                                 $virtualNetworkName `
  -ResourceGroupName                    $resourceGroupName `
  -Location                             $location `
  -AddressPrefix                        $vnetAddressPrefix `
  -Subnet                               $webSubnet,`
                                        $mngSubnet
  $webSubnetId = (
    $vnetObj.Subnets |
    Where-Object { $_.Name -eq $webSubnetName }
    ).Id
  $mngSubnetId = (
    $vnetObj.Subnets |
    Where-Object { $_.Name -eq $mngSubnetName }
    ).Id

Write-Host "Creating Storage Account for boot diagnostic ..."
New-AzStorageAccount `
  -ResourceGroupName                    $resourceGroupName `
  -Name                                 $bootStorageAccName `
  -Location                             $location `
  -SkuName                              $bootStSkuName `
  -Kind                                 $bootStKind `
  -AccessTier                           $bootStAccessTier `
  -MinimumTlsVersion                    $bootStMinimumTlsVersion


for (($zone = 1); ($zone -le 2); ($zone++) ) {
  Write-Host "Creating a NIC for web server VM #${zone}..."
  $vmName = "$webVmName-$zone"
  $ipConfig = New-AzNetworkInterfaceIpConfig `
    -Name                                 "${vmName}-ipconfig" `
    -SubnetId                             $webSubnetId
  $nicObj = New-AzNetworkInterface -Force `
    -Name                                 "${vmName}-NIC" `
    -ResourceGroupName                    $resourceGroupName `
    -Location                             $location `
    -IpConfiguration                      $ipConfig
  Write-Host "Creating a web server VM #${zone}..."
  $vmconfig = New-AzVMConfig `
    -VMName                               $vmName `
    -VMSize                               $vmSize
  $vmconfig = Set-AzVMSourceImage `
    -VM                                   $vmconfig `
    -PublisherName                        $osPublisherName `
    -Offer                                $osOffer `
    -Skus                                 $osSku `
    -Version                              $osVersion
  $vmconfig = Set-AzVMOSDisk `
    -VM                                   $vmconfig `
    -Name                                 "${vmName}-OSDisk" `
    -CreateOption                         "FromImage" `
    -DeleteOption                         "Delete" `
    -DiskSizeInGB                         $osDiskSizeGB `
    -Caching                              "ReadWrite" `
    -StorageAccountType                   $osDiskType
  $vmconfig = Set-AzVMOperatingSystem `
    -VM                                   $vmconfig `
    -ComputerName                         $vmName `
    -Linux                                `
    -Credential                           $cred
  $vmconfig = Add-AzVMNetworkInterface `
    -VM                                   $vmconfig `
    -Id                                   $nicObj.Id
  $vmconfig = Set-AzVMBootDiagnostic `
    -VM                                   $vmconfig `
    -Enable                               `
    -ResourceGroupName                    $resourceGroupName `
    -StorageAccountName                   $bootStorageAccName
  New-AzVM `
    -ResourceGroupName                    $resourceGroupName `
    -Location                             $location `
    -VM                                   $vmconfig
  $scriptUrl = "https://raw.githubusercontent.com/YegorVolkov/azure_task_18_configure_load_balancing/dev/install-app.sh"
  Set-AzVMExtension `
    -ResourceGroupName                    $resourceGroupName `
    -VMName                               $vmName `
    -Name                                 'CustomScript' `
    -Publisher                            'Microsoft.Azure.Extensions' `
    -ExtensionType                        'CustomScript' `
    -TypeHandlerVersion                   '2.1' `
    -Settings @{
        "fileUris" =                      @($scriptUrl)
        "commandToExecute" =              './install-app.sh'
    }
}

Write-Host "Creating an SSH key resource ..."
New-AzSshKey `
  -Name                                 $sshKeyName `
  -ResourceGroupName                    $resourceGroupName `
  -PublicKey                            $sshKeyPublicKey
Write-Host "Creating a public IP ..."
$jumpboxVmPubipObj = New-AzPublicIpAddress `
  -Name                                 "${jumpboxVmName}-pubip" `
  -ResourceGroupName                    $resourceGroupName `
  -Location                             $location `
  -Sku                                  "Basic" `
  -AllocationMethod                     "Dynamic" `
  -DomainNameLabel                      $dnsLabel
Write-Host "Creating a NIC for management VM ..."
$ipConfig = New-AzNetworkInterfaceIpConfig `
  -Name                                 "${jumpboxVmName}-ipconfig" `
  -SubnetId                             $mngSubnetId `
  -PublicIpAddressId                    $jumpboxVmPubipObj.Id
$nicObj = New-AzNetworkInterface -Force `
  -Name                                 "${jumpboxVmName}-NIC" `
  -ResourceGroupName                    $resourceGroupName `
  -Location                             $location `
  -IpConfiguration                      $ipConfig
Write-Host "Creating a management VM ..."
$vmconfig = New-AzVMConfig `
  -VMName                               $jumpboxVmName `
  -VMSize                               $vmSize
$vmconfig = Set-AzVMSourceImage `
  -VM                                   $vmconfig `
  -PublisherName                        $osPublisherName `
  -Offer                                $osOffer `
  -Skus                                 $osSku `
  -Version                              $osVersion
$vmconfig = Set-AzVMOSDisk `
  -VM                                   $vmconfig `
  -Name                                 "${jumpboxVmName}-OSDisk" `
  -CreateOption                         FromImage `
  -DeleteOption                         Delete `
  -DiskSizeInGB                         $osDiskSizeGB `
  -Caching                              ReadWrite `
  -StorageAccountType                   $osDiskType
$vmconfig = Set-AzVMOperatingSystem `
  -VM                                   $vmconfig `
  -ComputerName                         $jumpboxVmName `
  -Linux                                `
  -Credential                           $cred `
  -DisablePasswordAuthentication
$vmconfig = Add-AzVMNetworkInterface `
  -VM                                   $vmconfig `
  -Id                                   $nicObj.Id
$vmconfig = Set-AzVMBootDiagnostic `
  -VM                                   $vmconfig `
  -Enable                               `
  -ResourceGroupName                    $resourceGroupName `
  -StorageAccountName                   $bootStorageAccName
New-AzVM `
  -ResourceGroupName                    $resourceGroupName `
  -Location                             $location `
  -VM                                   $vmconfig `
  -SshKeyName                           $sshKeyName

Write-Host "Creating a Private Dns Zone ..."
New-AzPrivateDnsZone `
  -Name                                 $privateDnsZoneName `
  -ResourceGroupName                    $resourceGroupName

Write-Host "Auto-Assigning the DNS to VMs via 'Private Dns Virtual Network Link' ..."
New-AzPrivateDnsVirtualNetworkLink `
  -Name                                 "dnslink.${privateDnsZoneName}" `
  -ResourceGroupName                    $resourceGroupName `
  -ZoneName                             $privateDnsZoneName `
  -VirtualNetworkId                     $vnetObj.Id `
  -EnableRegistration

Write-Host "Creating a load balancer ..."
Write-Host "Creating load balancer frontend configuration ..."
$lbFeIpConfig = New-AzLoadBalancerFrontendIpConfig `
  -Name                                 $lbFeName `
  -SubnetId                             $webSubnetId `
  -PrivateIpAddress                     $lbFeIpAddress
Write-Host "Creating backend address pool configuration ..."
$lbBeIpPoolConfig = New-AzLoadBalancerBackendAddressPoolConfig `
  -Name                                 $lbBeName
Write-Host "Creating the load balancer rule ..."
$lbRule = New-AzLoadBalancerRuleConfig `
  -Name                                 $lbRuleName `
  -Protocol                             "tcp" `
  -FrontendPort                         $lbFePort `
  -BackendPort                          $lbBePort `
  -IdleTimeoutInMinutes                 "15" `
  -FrontendIpConfiguration              $lbFeIpConfig `
  -BackendAddressPool                   $lbBeIpPoolConfig `
  -EnableTcpReset
Write-Host "Creating the health probe ..."
$lbHealthProbe = New-AzLoadBalancerProbeConfig `
  -Name                                 $lbHealthProbeName `
  -Protocol                             "tcp" `
  -Port                                 $lbBePort `
  -IntervalInSeconds                    "360" `
  -ProbeCount                           "5"
Write-Host "Creating the load balancer resource ..."
New-AzLoadBalancer `
  -Name                                 $lbName `
  -ResourceGroupName                    $resourceGroupName `
  -Location                             $location `
  -Sku                                  "Standard" `
  -FrontendIpConfiguration              $lbFeIpConfig `
  -BackendAddressPool                   $lbBeIpPoolConfig `
  -LoadBalancingRule                    $lbRule `
  -Probe                                $lbHealthProbe

Write-Host "Adding VMs to the backend pool"
$webServerVMs = Get-AzVm `
  -ResourceGroupName $resourceGroupName | Where-Object {
    $_.Name.StartsWith($webVmName)
  }
  foreach ($vm in $webServerVMs) {
    $vmname = $vm.Name
    $nic = Get-AzNetworkInterface `
      -ResourceGroupName $resourceGroupName | Where-Object {
        $_.Id -eq $vm.NetworkProfile.NetworkInterfaces.Id
        }
        $ipCfg = $nic.IpConfigurations | Where-Object {
          $_.Name -eq "${vmname}-ipconfig"
          }
    $ipCfg.LoadBalancerBackendAddressPools.Add($lbBeIpPoolConfig)
    Set-AzNetworkInterface `
      -NetworkInterface                 $nic
  }

Write-Host `
  "Creating an 'A' DNS record" `
  "(Assigning the ${webSetSubdomain}.$privateDnsZoneName domain name" `
  " to the load balancer front end ip $lbFeIpAddress)"
New-AzPrivateDnsRecordSet `
  -Name                                 $webSetSubdomain `
  -RecordType                           A `
  -ResourceGroupName                    $resourceGroupName `
  -TTL                                  1800 `
  -ZoneName                             $privateDnsZoneName `
  -PrivateDnsRecords                    @(
    New-AzPrivateDnsRecordConfig `
      -IPv4Address                      $lbFeIpAddress
    )
