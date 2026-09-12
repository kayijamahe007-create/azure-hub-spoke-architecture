# Troubleshooting Notes — Manual Azure Portal Deployment

Real issues hit while deploying this architecture by hand in the Azure Portal,
kept here as a record of what actually goes wrong (and why) versus what the
docs imply.

### "There is already a resource with the same name and type"
Happens when a wizard defaults to **Create new** for a VNet that already exists
in the target resource group. Fix: switch to **Use existing** and select the
VNet from the dropdown instead of retyping its name.

### "Force Tunneling requires this virtual network have a subnet named AzureFirewallManagementSubnet"
Caused by **Enable Firewall Management NIC** being checked by default when no
public IP is yet selected. This subnet is only needed for forced-tunneling
scenarios (routing all outbound traffic back through on-premises), which this
design doesn't use. Fix: uncheck "Enable Firewall Management NIC" — the error
clears immediately.

### VPN Gateway asking for a second public IP
Caused by **Enable active-active mode** defaulting to Enabled. Active-active is
for dual independent tunnels (extra redundancy, extra cost) — not required for
a single lab/production tunnel. Fix: set it to **Disabled**.

### "Select a different virtual network. These virtual networks are already peered"
Azure won't create a duplicate peering link between two VNets that are already
peered. If this appears unexpectedly, check the source VNet's **Peerings** list
first — it likely already has the link you're trying to recreate.

### Peering is always two-sided
Creating a peering from VNet A to VNet B does **not** automatically create the
return link from B to A. Both directions must be created explicitly, each with
its own settings (this matters especially for gateway transit, below).

### Global VNet Peering + gateway sharing
When peering two regional hubs where only one has a VPN Gateway:
- On the **hub with the gateway**: enable **"Allow gateway transit"** — this
  offers the gateway to the peered network.
- On the **hub without the gateway**: enable **"Use remote gateways"** — this
  is the setting that actually lets that VNet use the other's gateway.
- These are two different checkboxes with easily-confused names; double-check
  which VNet you're configuring before checking either one.

### Region set incorrectly on VNet creation
A VNet's region cannot be changed after creation — there is no "move" option
for location the way there is for resource group. If created in the wrong
region, the only fix is deleting and recreating it.

### Route tables must be created and attached per region
Each region's firewall has its own private IP, so each region needs its own
route table pointing `0.0.0.0/0` to its own firewall — a route table built for
Region A's firewall IP will not work if attached to Region B's spoke subnets.
