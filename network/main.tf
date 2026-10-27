module "central_config" {
  source = "../config"
  prefix = var.prefix
}

locals {
  net = module.central_config.networking

  project_ids = merge(
    { for p in values(module.central_config.projects) : p.name => p.project_id },
    var.project_id_overrides,
  )

  vpc_routes = {
    for vpc_key, vpc in local.net.vpcs : vpc_key => {
      for r in local.net.routes : r.name => {
        dest_range    = r.dest_range
        next_hop_type = "gateway"
        next_hop      = r.next_hop_gateway
        priority      = r.priority
      } if r.vpc_ref == vpc_key
    }
  }

  producer_spokes = {
    for s in local.net.ncc.spokes : s.name => s if s.type == "linked_producer_vpc_network"
  }

  vpc_spokes = {
    for s in local.net.ncc.spokes : s.name => s if s.type == "linked_vpc_network"
  }

  vpn_spokes = {
    for s in local.net.ncc.spokes : s.name => s if s.type == "linked_vpn_tunnels"
  }

  bgp_routers = {
    for k, r in local.net.routers : k => r if r.bgp != null
  }

  vpn_tunnels = merge([
    for vpn_key, v in local.net.vpns : {
      for name, t in v.tunnels : name => merge(t, { vpn_ref = vpn_key })
    }
  ]...)

  # Placeholders until the network team confirms them. Kept in locals so a
  # test harness can replace them with an override file.
  bgp_asn  = { for k, r in local.bgp_routers : k => r.bgp.asn }
  vpn_peer = { for k, v in local.net.vpns : k => v.peer }
  vpn_psk  = { for k, t in local.vpn_tunnels : k => data.google_secret_manager_secret_version.psk[k].secret_data }
}

# Stage 4: VPCs, subnets, Private Service Access and Google API routes.

module "vpc" {
  source   = "git::https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/net-vpc?ref=${var.cff_version}&depth=1"
  for_each = local.net.vpcs

  project_id                        = local.project_ids[each.value.project_ref]
  name                              = each.value.network_name
  routing_mode                      = each.value.routing_mode
  delete_default_routes_on_create   = lookup(each.value, "delete_default_routes_on_create", false)
  firewall_policy_enforcement_order = each.value.network_firewall_policy_enforcement_order
  create_googleapis_routes          = null
  routes                            = local.vpc_routes[each.key]

  subnets = [
    for name, s in each.value.subnets : {
      name                  = name
      region                = s.region
      ip_cidr_range         = s.ip_cidr_range
      enable_private_access = lookup(s, "private_ip_google_access", false)
      flow_logs_config = lookup(s, "flow_logs_enabled", false) ? {
        aggregation_interval = "INTERVAL_5_SEC"
        flow_sampling        = 0.5
        metadata             = "INCLUDE_ALL_METADATA"
      } : null
      secondary_ip_ranges = {
        for range_name, cidr in coalesce(lookup(s, "secondary_ip_ranges", null), {}) :
        range_name => { ip_cidr_range = cidr }
      }
    } if lookup(s, "purpose", null) == null
  ]

  subnets_proxy_only = [
    for name, s in each.value.subnets : {
      name          = name
      region        = s.region
      ip_cidr_range = s.ip_cidr_range
      active        = lookup(s, "role", "ACTIVE") == "ACTIVE"
    } if lookup(s, "purpose", null) == "REGIONAL_MANAGED_PROXY"
  ]

  subnets_psc = [
    for name, s in each.value.subnets : {
      name          = name
      region        = s.region
      ip_cidr_range = s.ip_cidr_range
    } if lookup(s, "purpose", null) == "PRIVATE_SERVICE_CONNECT"
  ]

  psa_configs = lookup(each.value, "psa_ranges", null) == null ? [] : [{
    ranges        = { for range_name, r in each.value.psa_ranges : range_name => r.ip_cidr_range }
    export_routes = anytrue([for r in values(each.value.psa_ranges) : lookup(r, "export_custom_routes", false)])
    range_prefix  = each.key
    # Google keeps the connection in use for some time after a Cloud SQL
    # instance on it is deleted, so a destroy would fail. ABANDON leaves it to
    # go with the network.
    deletion_policy = "ABANDON"
  }]
}

# Stage 5: Cloud NAT with its router, firewall policies, NCC hub and VPC spokes.

module "nat" {
  source   = "git::https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/net-cloudnat?ref=${var.cff_version}&depth=1"
  for_each = local.net.cloud_nats

  project_id     = local.project_ids[each.value.project_ref]
  region         = each.value.region
  name           = each.value.name
  router_create  = true
  router_name    = local.net.routers[each.value.router_ref].name
  router_network = module.vpc[local.net.routers[each.value.router_ref].vpc_ref].self_link
}

# A VPC takes one global network firewall policy, and only from its own
# project. Each VPC gets one policy holding every rule from every YAML policy
# associated with it.
locals {
  vpc_firewall_rules = {
    for vpc_key, vpc in local.net.vpcs : vpc_key => merge([
      for policy_name, policy in local.net.firewall_policies : {
        for rule_name, r in policy.rules : "${policy_name}-${rule_name}" => r
      } if contains(policy.associations, vpc_key)
    ]...)
  }
}

module "firewall_policy" {
  source   = "git::https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git//modules/net-firewall-policy?ref=${var.cff_version}&depth=1"
  for_each = local.vpc_firewall_rules

  name      = "fw-${each.key}"
  parent_id = local.project_ids[local.net.vpcs[each.key].project_ref]
  region    = "global"

  attachments = {
    (each.key) = module.vpc[each.key].id
  }

  egress_rules = {
    for rule_name, r in each.value : rule_name => {
      priority = r.priority
      action   = r.action
      match = {
        destination_ranges = lookup(r, "destination_ranges", null)
        layer4_configs     = [for p in split(",", r.protocol) : { protocol = p, ports = lookup(r, "ports", null) }]
      }
    } if r.direction == "EGRESS"
  }

  ingress_rules = {
    for rule_name, r in each.value : rule_name => {
      priority = r.priority
      action   = r.action
      match = {
        source_ranges  = lookup(r, "source_ranges", null)
        layer4_configs = [for p in split(",", r.protocol) : { protocol = p, ports = lookup(r, "ports", null) }]
      }
    } if r.direction == "INGRESS"
  }
}

resource "google_network_connectivity_hub" "hub" {
  for_each = { for h in local.net.ncc.hubs : h.name => h }

  project         = local.project_ids[each.value.project_ref]
  name            = each.value.name
  preset_topology = each.value.preset_topology
  export_psc      = each.value.export_psc
}

resource "google_network_connectivity_group" "group" {
  for_each = { for g in local.net.ncc.groups : g.name => g }

  project = google_network_connectivity_hub.hub[each.value.hub_ref].project
  hub     = google_network_connectivity_hub.hub[each.value.hub_ref].id
  name    = each.value.name

  auto_accept {
    auto_accept_projects = distinct([for p in each.value.auto_accept_projects : local.project_ids[p]])
  }
}

# A VPC spoke is created in the project that owns the VPC.
resource "google_network_connectivity_spoke" "vpc" {
  for_each = local.vpc_spokes

  project  = local.project_ids[local.net.vpcs[each.value.vpc_ref].project_ref]
  location = "global"
  name     = each.value.name
  hub      = google_network_connectivity_hub.hub[each.value.hub_ref].id
  group    = google_network_connectivity_group.group[each.value.group_ref].id

  linked_vpc_network {
    uri                   = module.vpc[each.value.vpc_ref].self_link
    exclude_export_ranges = lookup(each.value, "exclude_export_ranges", [])
  }

  depends_on = [module.vpc]
}

resource "google_network_connectivity_spoke" "producer" {
  for_each = local.producer_spokes

  project  = local.project_ids[local.net.vpcs[each.value.vpc_ref].project_ref]
  location = "global"
  name     = each.value.name
  hub      = google_network_connectivity_hub.hub[each.value.hub_ref].id
  group    = google_network_connectivity_group.group[each.value.group_ref].id

  linked_producer_vpc_network {
    network = module.vpc[each.value.vpc_ref].self_link
    peering = each.value.peering
  }

  depends_on = [google_network_connectivity_spoke.vpc]
}

# Stage 6: hybrid connectivity. Cloud Routers with BGP, HA VPN to the
# on-premises edges, and one VPN spoke per region.

resource "google_compute_router" "bgp" {
  for_each = local.bgp_routers

  project = local.project_ids[each.value.project_ref]
  name    = each.value.name
  region  = each.value.region
  network = module.vpc[each.value.vpc_ref].self_link

  bgp {
    asn            = local.bgp_asn[each.key]
    advertise_mode = each.value.bgp.advertise_mode

    dynamic "advertised_ip_ranges" {
      for_each = each.value.bgp.advertised_ip_ranges
      content {
        range = advertised_ip_ranges.value
      }
    }
  }
}

resource "google_compute_ha_vpn_gateway" "vpn" {
  for_each = local.net.vpns

  project = local.project_ids[each.value.project_ref]
  name    = each.value.name
  region  = each.value.region
  network = module.vpc[each.value.vpc_ref].self_link
}

# One public IP per edge: both tunnels of a gateway end on it.
resource "google_compute_external_vpn_gateway" "peer" {
  for_each = local.net.vpns

  project         = local.project_ids[each.value.project_ref]
  name            = each.value.peer.name
  redundancy_type = "SINGLE_IP_INTERNALLY_REDUNDANT"

  interface {
    id         = 0
    ip_address = local.vpn_peer[each.key].ip_address
  }
}

# The key is held in state; the state backend must be access controlled.
data "google_secret_manager_secret_version" "psk" {
  for_each = local.vpn_tunnels

  project = local.project_ids[local.net.vpns[each.value.vpn_ref].project_ref]
  secret  = each.value.psk_secret
}

resource "google_compute_vpn_tunnel" "vpn" {
  for_each = local.vpn_tunnels

  project                         = local.project_ids[local.net.vpns[each.value.vpn_ref].project_ref]
  name                            = each.key
  region                          = local.net.vpns[each.value.vpn_ref].region
  vpn_gateway                     = google_compute_ha_vpn_gateway.vpn[each.value.vpn_ref].id
  vpn_gateway_interface           = each.value.vpn_gateway_interface
  peer_external_gateway           = google_compute_external_vpn_gateway.peer[each.value.vpn_ref].id
  peer_external_gateway_interface = 0
  shared_secret                   = local.vpn_psk[each.key]
  router                          = google_compute_router.bgp[local.net.vpns[each.value.vpn_ref].router_ref].id
  ike_version                     = 2
}

resource "google_compute_router_interface" "vpn" {
  for_each = local.vpn_tunnels

  project    = local.project_ids[local.net.vpns[each.value.vpn_ref].project_ref]
  name       = "if-${each.key}"
  region     = local.net.vpns[each.value.vpn_ref].region
  router     = google_compute_router.bgp[local.net.vpns[each.value.vpn_ref].router_ref].name
  ip_range   = "${each.value.bgp_ip}/30"
  vpn_tunnel = google_compute_vpn_tunnel.vpn[each.key].name
}

resource "google_compute_router_peer" "vpn" {
  for_each = local.vpn_tunnels

  project                   = local.project_ids[local.net.vpns[each.value.vpn_ref].project_ref]
  name                      = "peer-${each.key}"
  region                    = local.net.vpns[each.value.vpn_ref].region
  router                    = google_compute_router.bgp[local.net.vpns[each.value.vpn_ref].router_ref].name
  interface                 = google_compute_router_interface.vpn[each.key].name
  peer_ip_address           = each.value.peer_bgp_ip
  peer_asn                  = local.vpn_peer[each.value.vpn_ref].remote_asn
  advertised_route_priority = local.net.routers[local.net.vpns[each.value.vpn_ref].router_ref].bgp.advertised_route_priority

  bfd {
    session_initialization_mode = local.net.routers[local.net.vpns[each.value.vpn_ref].router_ref].bgp.bfd.session_initialization_mode
    min_transmit_interval       = local.net.routers[local.net.vpns[each.value.vpn_ref].router_ref].bgp.bfd.min_transmit_interval
    min_receive_interval        = local.net.routers[local.net.vpns[each.value.vpn_ref].router_ref].bgp.bfd.min_receive_interval
    multiplier                  = local.net.routers[local.net.vpns[each.value.vpn_ref].router_ref].bgp.bfd.multiplier
  }
}

# A VPN spoke is regional and lives in the project that holds the tunnels.
resource "google_network_connectivity_spoke" "vpn" {
  for_each = local.vpn_spokes

  project  = local.project_ids[local.net.vpns[each.value.vpn_refs[0]].project_ref]
  location = each.value.region
  name     = each.value.name
  hub      = google_network_connectivity_hub.hub[each.value.hub_ref].id
  group    = google_network_connectivity_group.group[each.value.group_ref].id

  linked_vpn_tunnels {
    uris = [
      for name, t in local.vpn_tunnels : google_compute_vpn_tunnel.vpn[name].self_link
      if contains(each.value.vpn_refs, t.vpn_ref)
    ]
    site_to_site_data_transfer = each.value.site_to_site_data_transfer
  }

  depends_on = [google_compute_router_peer.vpn]
}

# Stage 6: Private Service Connect endpoint for Google APIs.

resource "google_compute_global_address" "psc" {
  for_each = { for e in local.net.psc_endpoints : e.name => e }

  project      = local.project_ids[each.value.project_ref]
  name         = "${each.key}-address"
  purpose      = "PRIVATE_SERVICE_CONNECT"
  address_type = "INTERNAL"
  address      = each.value.address
  network      = module.vpc[each.value.vpc_ref].id
}

resource "google_compute_global_forwarding_rule" "psc" {
  for_each = { for e in local.net.psc_endpoints : e.name => e }

  project               = local.project_ids[each.value.project_ref]
  name                  = each.key
  target                = each.value.target
  network               = module.vpc[each.value.vpc_ref].id
  ip_address            = google_compute_global_address.psc[each.key].id
  load_balancing_scheme = ""
}

# Stage 6: DNS. Private and forwarding zones live in the hub; every VPC in a
# zone's peered_by gets a peering zone pointing at the hub for that name.

locals {
  dns_private_zones = merge([
    for entry_key, e in local.net.dns : {
      for zone_key, z in lookup(e, "private_zones", {}) : "${entry_key}-${zone_key}" => {
        project   = local.project_ids[e.project_ref]
        vpc_ref   = e.vpc_ref
        dns_name  = z.dns_name
        records   = z.records
        peered_by = lookup(z, "peered_by", [])
      }
    }
  ]...)

  dns_forwarding_zones = merge([
    for entry_key, e in local.net.dns : {
      for zone_key, z in coalesce(lookup(e, "forwarding_zones", null), {}) : "${entry_key}-${zone_key}" => {
        project   = local.project_ids[e.project_ref]
        vpc_ref   = e.vpc_ref
        dns_name  = z.dns_name
        targets   = z.targets
        peered_by = lookup(z, "peered_by", [])
      }
    }
  ]...)

  # Record keys are <label>-<type>; the label "wildcard" means "*".
  dns_records = merge([
    for zone_key, z in local.dns_private_zones : {
      for rec_key, value in z.records : "${zone_key}/${rec_key}" => {
        zone  = zone_key
        type  = upper(element(split("-", rec_key), length(split("-", rec_key)) - 1))
        name  = "${replace(join("-", slice(split("-", rec_key), 0, length(split("-", rec_key)) - 1)), "wildcard", "*")}.${z.dns_name}"
        datas = [for d in split(",", value) : trimspace(d)]
      }
    }
  ]...)

  dns_peering_zones = merge([
    for zone_key, z in merge(local.dns_private_zones, local.dns_forwarding_zones) : {
      for spoke in z.peered_by : "${spoke}-to-${zone_key}" => {
        project    = local.project_ids[local.net.vpcs[spoke].project_ref]
        vpc_ref    = spoke
        dns_name   = z.dns_name
        target_vpc = z.vpc_ref
      }
    }
  ]...)
}

# Google assigns the forwarder addresses when the policy is created, and
# on-premises DNS is configured with them, so the policy must not be recreated.
resource "google_dns_policy" "inbound" {
  for_each = { for k, e in local.net.dns : k => e if e.inbound_policy }

  project                   = local.project_ids[each.value.project_ref]
  name                      = "${each.key}-inbound"
  enable_inbound_forwarding = true

  networks {
    network_url = module.vpc[each.value.vpc_ref].self_link
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_dns_managed_zone" "private" {
  for_each = local.dns_private_zones

  project    = each.value.project
  name       = each.key
  dns_name   = each.value.dns_name
  visibility = "private"

  private_visibility_config {
    networks {
      network_url = module.vpc[each.value.vpc_ref].self_link
    }
  }
}

resource "google_dns_record_set" "private" {
  for_each = local.dns_records

  project      = local.dns_private_zones[each.value.zone].project
  managed_zone = google_dns_managed_zone.private[each.value.zone].name
  name         = each.value.name
  type         = each.value.type
  ttl          = 300
  rrdatas      = each.value.datas
}

# Queries leave from 35.199.192.0/19 through the tunnels, because the targets
# are private addresses reached over the VPN.
resource "google_dns_managed_zone" "forwarding" {
  for_each = local.dns_forwarding_zones

  project    = each.value.project
  name       = each.key
  dns_name   = each.value.dns_name
  visibility = "private"

  private_visibility_config {
    networks {
      network_url = module.vpc[each.value.vpc_ref].self_link
    }
  }

  forwarding_config {
    dynamic "target_name_servers" {
      for_each = each.value.targets
      content {
        ipv4_address = target_name_servers.value
      }
    }
  }
}

resource "google_dns_managed_zone" "peering" {
  for_each = local.dns_peering_zones

  project    = each.value.project
  name       = each.key
  dns_name   = each.value.dns_name
  visibility = "private"

  private_visibility_config {
    networks {
      network_url = module.vpc[each.value.vpc_ref].self_link
    }
  }

  peering_config {
    target_network {
      network_url = module.vpc[each.value.target_vpc].self_link
    }
  }
}
