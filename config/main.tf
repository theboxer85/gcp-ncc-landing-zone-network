# Reads network.yaml and hands it to the network stage. Project IDs are the
# project name with the prefix in front.

variable "prefix" {
  description = "Prepended to each project name to form its project ID."
  type        = string
}

locals {
  network = yamldecode(file("${path.module}/network.yaml"))

  project_names = distinct([for v in values(local.network.vpcs) : v.project_ref])
}

output "projects" {
  value = {
    for name in local.project_names : name => {
      name       = name
      project_id = "${var.prefix}-${name}"
    }
  }
}

output "networking" {
  value = {
    vpcs              = local.network.vpcs
    routers           = lookup(local.network, "routers", {})
    cloud_nats        = lookup(local.network, "cloud_nats", {})
    vpns              = lookup(local.network, "vpns", {})
    firewall_policies = lookup(local.network, "firewall_policies", {})
    dns               = lookup(local.network, "dns", {})
    ncc               = local.network.ncc
    routes            = lookup(local.network, "routes", [])
    psc_endpoints     = lookup(local.network, "psc_endpoints", [])
  }
}
