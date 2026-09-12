<#
==============================================================================
 Deploy-AKL-HubSpoke-Architecture.ps1

 What this script builds, in plain words:
   - A "hub" VNet in each of 2 regions. Think of the hub as a security
     checkpoint every other network must pass through.
   - "Spoke" VNets (App tier, Data tier) in each region, connected only
     to their region's hub.
   - A firewall in each hub that inspects traffic between spokes.
   - Azure Bastion in each hub, so admins never need a public IP on a VM.
   - A VPN Gateway in the primary region's hub, for the on-premises link.
   - Global VNet Peering connecting the two hubs together.
   - Route tables that force spoke traffic through the firewall.

 Company: Alex_Kayijamahe Ltd
 Run this in PowerShell 7+ with the Az module installed:
     Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force
==============================================================================
#>

# ---------------------------------------------------------------------------
# STEP 0 — Sign in and pick the subscription
# ---------------------------------------------------------------------------
Connect-AzAccount
# If you have more than one subscription, uncomment and set the right one:
# Set-AzContext -Subscription "<your-subscription-name-or-id>"

# ---------------------------------------------------------------------------
# STEP 1 — Company-wide variables
# All resource names use the "akl" prefix (Alex_Kayijamahe Ltd), and every
# resource gets a CompanyName tag so it's easy to find and bill later.
# ---------------------------------------------------------------------------
$CompanyName   = "Alex_Kayijamahe Ltd"
$Prefix        = "akl"
$Tags          = @{ CompanyName = $CompanyName; Environment = "Production" }

# Region A = primary, Region B = secondary / DR
$RegionA       = "canadacentral"
$RegionB       = "canadaeast"

# On-premises network you're connecting from (replace with the real range)
$OnPremCidr    = "192.168.0.0/16"
$OnPremGatewayPublicIp = "203.0.113.10"   # the public IP of your on-prem VPN device

# A shared admin password object for the VPN pre-shared key (replace this!)
$VpnSharedKey  = "ChangeThisSharedKey123!"

# ---------------------------------------------------------------------------
# STEP 2 — Resource groups (one per region keeps things tidy and lets you
# delete/redeploy a whole region without touching the other one)
# ---------------------------------------------------------------------------
$RgA = "rg-$Prefix-network-cac"
$RgB = "rg-$Prefix-network-cae"

New-AzResourceGroup -Name $RgA -Location $RegionA -Tag $Tags
New-AzResourceGroup -Name $RgB -Location $RegionB -Tag $Tags

# ===========================================================================
#  REGION A  —  primary hub + spokes (Canada Central)
# ===========================================================================

# ---------------------------------------------------------------------------
# STEP 3 — Hub VNet in Region A
# The hub needs three special subnets:
#   AzureFirewallSubnet   -> must be named exactly this, min /26
#   GatewaySubnet         -> must be named exactly this, min /27
#   AzureBastionSubnet    -> must be named exactly this, min /26
# ---------------------------------------------------------------------------
$fwSubnetA   = New-AzVirtualNetworkSubnetConfig -Name "AzureFirewallSubnet"  -AddressPrefix "10.10.0.0/26"
$gwSubnetA   = New-AzVirtualNetworkSubnetConfig -Name "GatewaySubnet"       -AddressPrefix "10.10.1.0/27"
$basSubnetA  = New-AzVirtualNetworkSubnetConfig -Name "AzureBastionSubnet"  -AddressPrefix "10.10.2.0/26"

$hubVnetA = New-AzVirtualNetwork -Name "vnet-$Prefix-hub-cac" -ResourceGroupName $RgA `
    -Location $RegionA -AddressPrefix "10.10.0.0/16" `
    -Subnet $fwSubnetA, $gwSubnetA, $basSubnetA -Tag $Tags

# ---------------------------------------------------------------------------
# STEP 4 — Spoke VNets in Region A (App tier and Data tier)
# ---------------------------------------------------------------------------
$appSubnetA = New-AzVirtualNetworkSubnetConfig -Name "snet-app" -AddressPrefix "10.11.1.0/24"
$appVnetA = New-AzVirtualNetwork -Name "vnet-$Prefix-app-cac" -ResourceGroupName $RgA `
    -Location $RegionA -AddressPrefix "10.11.0.0/16" -Subnet $appSubnetA -Tag $Tags

$dataSubnetA = New-AzVirtualNetworkSubnetConfig -Name "snet-data" -AddressPrefix "10.12.1.0/24"
$dataVnetA = New-AzVirtualNetwork -Name "vnet-$Prefix-data-cac" -ResourceGroupName $RgA `
    -Location $RegionA -AddressPrefix "10.12.0.0/16" -Subnet $dataSubnetA -Tag $Tags

# ---------------------------------------------------------------------------
# STEP 5 — Peer each spoke to the Region A hub (two-way peering)
# ---------------------------------------------------------------------------
Add-AzVirtualNetworkPeering -Name "peer-app-to-hub-cac" -VirtualNetwork $appVnetA `
    -RemoteVirtualNetworkId $hubVnetA.Id -AllowForwardedTraffic
Add-AzVirtualNetworkPeering -Name "peer-hub-to-app-cac" -VirtualNetwork $hubVnetA `
    -RemoteVirtualNetworkId $appVnetA.Id -AllowForwardedTraffic

Add-AzVirtualNetworkPeering -Name "peer-data-to-hub-cac" -VirtualNetwork $dataVnetA `
    -RemoteVirtualNetworkId $hubVnetA.Id -AllowForwardedTraffic
Add-AzVirtualNetworkPeering -Name "peer-hub-to-data-cac" -VirtualNetwork $hubVnetA `
    -RemoteVirtualNetworkId $dataVnetA.Id -AllowForwardedTraffic

# ---------------------------------------------------------------------------
# STEP 6 — Azure Firewall in the Region A hub
# This is the "checkpoint" every spoke's traffic will be routed through.
# ---------------------------------------------------------------------------
$fwPipA = New-AzPublicIpAddress -Name "pip-$Prefix-fw-cac" -ResourceGroupName $RgA `
    -Location $RegionA -AllocationMethod Static -Sku Standard -Tag $Tags

$fwA = New-AzFirewall -Name "fw-$Prefix-cac" -ResourceGroupName $RgA -Location $RegionA `
    -VirtualNetwork $hubVnetA -PublicIpAddress $fwPipA -Tag $Tags

# ---------------------------------------------------------------------------
# STEP 7 — Azure Bastion in the Region A hub (secure admin access, no
# public IP needed on any VM)
# ---------------------------------------------------------------------------
$bastionPipA = New-AzPublicIpAddress -Name "pip-$Prefix-bastion-cac" -ResourceGroupName $RgA `
    -Location $RegionA -AllocationMethod Static -Sku Standard -Tag $Tags

New-AzBastion -Name "bas-$Prefix-cac" -ResourceGroupName $RgA `
    -PublicIpAddress $bastionPipA -VirtualNetwork $hubVnetA -Sku "Standard"

# ---------------------------------------------------------------------------
# STEP 8 — VPN Gateway in the Region A hub (the on-prem "backup road" —
# ExpressRoute is the primary road but its circuit is ordered through a
# connectivity provider, not created purely by script; see the note at
# the bottom of this file)
# ---------------------------------------------------------------------------
$gwPipA = New-AzPublicIpAddress -Name "pip-$Prefix-vpngw-cac" -ResourceGroupName $RgA `
    -Location $RegionA -AllocationMethod Dynamic -Sku Basic -Tag $Tags

$gwIpConfigA = New-AzVirtualNetworkGatewayIpConfig -Name "gwipconfig-cac" `
    -SubnetId ($hubVnetA.Subnets | Where-Object Name -eq "GatewaySubnet").Id `
    -PublicIpAddressId $gwPipA.Id

$vpnGwA = New-AzVirtualNetworkGateway -Name "vpngw-$Prefix-cac" -ResourceGroupName $RgA `
    -Location $RegionA -IpConfigurations $gwIpConfigA `
    -GatewayType Vpn -VpnType RouteBased -GatewaySku VpnGw1 -Tag $Tags

# Represents the on-prem VPN device as an Azure object
$localGw = New-AzLocalNetworkGateway -Name "lgw-$Prefix-onprem" -ResourceGroupName $RgA `
    -Location $RegionA -GatewayIpAddress $OnPremGatewayPublicIp -AddressPrefix $OnPremCidr -Tag $Tags

# The actual Site-to-Site connection, using the shared key defined above
New-AzVirtualNetworkGatewayConnection -Name "cn-$Prefix-onprem-to-cac" -ResourceGroupName $RgA `
    -Location $RegionA -VirtualNetworkGateway1 $vpnGwA -LocalNetworkGateway2 $localGw `
    -ConnectionType IPsec -SharedKey $VpnSharedKey -Tag $Tags

# ===========================================================================
#  REGION B  —  secondary hub + spokes (Canada East, DR)
#  Same pattern as Region A, different address space and no VPN gateway
#  (traffic to Region B arrives via Global VNet Peering from Region A)
# ===========================================================================

$fwSubnetB   = New-AzVirtualNetworkSubnetConfig -Name "AzureFirewallSubnet"  -AddressPrefix "10.20.0.0/26"
$basSubnetB  = New-AzVirtualNetworkSubnetConfig -Name "AzureBastionSubnet"  -AddressPrefix "10.20.2.0/26"

$hubVnetB = New-AzVirtualNetwork -Name "vnet-$Prefix-hub-cae" -ResourceGroupName $RgB `
    -Location $RegionB -AddressPrefix "10.20.0.0/16" `
    -Subnet $fwSubnetB, $basSubnetB -Tag $Tags

$appSubnetB = New-AzVirtualNetworkSubnetConfig -Name "snet-app" -AddressPrefix "10.21.1.0/24"
$appVnetB = New-AzVirtualNetwork -Name "vnet-$Prefix-app-cae" -ResourceGroupName $RgB `
    -Location $RegionB -AddressPrefix "10.21.0.0/16" -Subnet $appSubnetB -Tag $Tags

$dataSubnetB = New-AzVirtualNetworkSubnetConfig -Name "snet-data" -AddressPrefix "10.22.1.0/24"
$dataVnetB = New-AzVirtualNetwork -Name "vnet-$Prefix-data-cae" -ResourceGroupName $RgB `
    -Location $RegionB -AddressPrefix "10.22.0.0/16" -Subnet $dataSubnetB -Tag $Tags

Add-AzVirtualNetworkPeering -Name "peer-app-to-hub-cae" -VirtualNetwork $appVnetB `
    -RemoteVirtualNetworkId $hubVnetB.Id -AllowForwardedTraffic
Add-AzVirtualNetworkPeering -Name "peer-hub-to-app-cae" -VirtualNetwork $hubVnetB `
    -RemoteVirtualNetworkId $appVnetB.Id -AllowForwardedTraffic

Add-AzVirtualNetworkPeering -Name "peer-data-to-hub-cae" -VirtualNetwork $dataVnetB `
    -RemoteVirtualNetworkId $hubVnetB.Id -AllowForwardedTraffic
Add-AzVirtualNetworkPeering -Name "peer-hub-to-data-cae" -VirtualNetwork $hubVnetB `
    -RemoteVirtualNetworkId $dataVnetB.Id -AllowForwardedTraffic

$fwPipB = New-AzPublicIpAddress -Name "pip-$Prefix-fw-cae" -ResourceGroupName $RgB `
    -Location $RegionB -AllocationMethod Static -Sku Standard -Tag $Tags

$fwB = New-AzFirewall -Name "fw-$Prefix-cae" -ResourceGroupName $RgB -Location $RegionB `
    -VirtualNetwork $hubVnetB -PublicIpAddress $fwPipB -Tag $Tags

$bastionPipB = New-AzPublicIpAddress -Name "pip-$Prefix-bastion-cae" -ResourceGroupName $RgB `
    -Location $RegionB -AllocationMethod Static -Sku Standard -Tag $Tags

New-AzBastion -Name "bas-$Prefix-cae" -ResourceGroupName $RgB `
    -PublicIpAddress $bastionPipB -VirtualNetwork $hubVnetB -Sku "Standard"

# ===========================================================================
# STEP 9 — Global VNet Peering: connect Region A hub to Region B hub
# This is the "highway" between the two regions, over Microsoft's private
# backbone — no public internet involved.
# ===========================================================================
Add-AzVirtualNetworkPeering -Name "peer-hubA-to-hubB" -VirtualNetwork $hubVnetA `
    -RemoteVirtualNetworkId $hubVnetB.Id -AllowForwardedTraffic -AllowGatewayTransit
Add-AzVirtualNetworkPeering -Name "peer-hubB-to-hubA" -VirtualNetwork $hubVnetB `
    -RemoteVirtualNetworkId $hubVnetA.Id -AllowForwardedTraffic -UseRemoteGateways

# ===========================================================================
# STEP 10 — Route tables: force spoke traffic through the firewall
# Without this, spokes would route directly to each other or to the
# internet, bypassing the checkpoint entirely.
# ===========================================================================
$fwPrivateIpA = (Get-AzFirewall -Name "fw-$Prefix-cac" -ResourceGroupName $RgA).IpConfigurations[0].PrivateIPAddress

$routeToFwA = New-AzRouteConfig -Name "route-to-firewall" -AddressPrefix "0.0.0.0/0" `
    -NextHopType VirtualAppliance -NextHopIpAddress $fwPrivateIpA

$udrA = New-AzRouteTable -Name "rt-$Prefix-spokes-cac" -ResourceGroupName $RgA -Location $RegionA `
    -Route $routeToFwA -Tag $Tags

Set-AzVirtualNetworkSubnetConfig -Name "snet-app" -VirtualNetwork $appVnetA `
    -AddressPrefix "10.11.1.0/24" -RouteTable $udrA | Set-AzVirtualNetwork
Set-AzVirtualNetworkSubnetConfig -Name "snet-data" -VirtualNetwork $dataVnetA `
    -AddressPrefix "10.12.1.0/24" -RouteTable $udrA | Set-AzVirtualNetwork

# (Repeat the same route table pattern for Region B's spokes if desired)

Write-Host "Deployment complete for $CompanyName." -ForegroundColor Green

<#
==============================================================================
 NOTES

 1) ExpressRoute: you can create the circuit resource itself with
    New-AzExpressRouteCircuit, but the actual private connection only goes
    live once your connectivity provider (e.g. a telco or colo operator)
    provisions their side and you complete peering with them. That part
    happens outside PowerShell, through the provider. The VPN Gateway above
    is fully self-service and works as your immediate/backup path.

 2) NSGs: add Network Security Groups on snet-app and snet-data with
    New-AzNetworkSecurityGroup + New-AzNetworkSecurityRuleConfig for an
    extra layer of filtering beneath the firewall.

 3) Firewall rules: New-AzFirewall creates the firewall itself but not
    traffic rules. Add those with New-AzFirewallPolicy and
    New-AzFirewallPolicyFilterRuleCollectionGroup so it actually allows/
    denies the traffic you want.

 4) Cost: Azure Firewall, VPN Gateway, and Bastion are billed hourly even
    when idle. Stop/deallocate or remove test resources when you're done.
==============================================================================
#>
