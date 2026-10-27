output "vpcs" {
  value = { for k, v in module.vpc : k => v.self_link }
}

output "spokes" {
  value = merge(
    { for k, v in google_network_connectivity_spoke.vpc : k => v.state },
    { for k, v in google_network_connectivity_spoke.producer : k => v.state },
    { for k, v in google_network_connectivity_spoke.vpn : k => v.state },
  )
}

# Sent to the network team: the peer addresses for each tunnel.
output "vpn_gateway_ips" {
  value = {
    for name, t in local.vpn_tunnels : name =>
    google_compute_ha_vpn_gateway.vpn[t.vpn_ref].vpn_interfaces[t.vpn_gateway_interface].ip_address
  }
}
