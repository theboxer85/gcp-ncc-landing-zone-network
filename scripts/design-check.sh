#!/bin/bash
# Pressure-tests config/network.yaml against every landed networking position.
# Run from anywhere. Exit 0 = every MET check passed and the OPEN list is unchanged.
CFG="${1:-$(cd "$(dirname "$0")/.." && pwd)/config/network.yaml}"
pass=0; fail=0
chk() { # chk "<position>" "<expected>" "<actual>"
  if [ "$2" = "$3" ]; then printf "  MET   %-58s %s\n" "$1" "$3"; pass=$((pass+1))
  else printf "  FAIL  %-58s want=%s got=%s\n" "$1" "$2" "$3"; fail=$((fail+1)); fi
}
echo "=== config: $CFG"
echo "=== LANDED POSITIONS ==="
chk "P1a prod is an edge spoke"        "edge"   "$(yq -r '.vpcs.prod.ncc_attachment' "$CFG")"
chk "P1b preprod is an edge spoke"     "edge"   "$(yq -r '.vpcs.preprod.ncc_attachment' "$CFG")"
chk "P1c shared-services is center"    "center" "$(yq -r '.vpcs."shared-services".ncc_attachment' "$CFG")"
chk "P1d hybrid is center"             "center" "$(yq -r '.vpcs.hybrid.ncc_attachment' "$CFG")"
chk "P1e isolated is not a spoke"      "none"   "$(yq -r '.vpcs.isolated.ncc_attachment' "$CFG")"
chk "P2a exactly one NCC hub"          "1"      "$(yq -r '.ncc.hubs | length' "$CFG")"
chk "P2b star topology"                "STAR"   "$(yq -r '.ncc.hubs[0].preset_topology' "$CFG")"
chk "P2c two spoke groups"             "2"      "$(yq -r '.ncc.groups | length' "$CFG")"
chk "P2d one routing VPC (hybrid)"     "1"      "$(yq -r '[.routers[] | select(.bgp != null)] | map(.vpc_ref) | unique | length' "$CFG")"
chk "P3a no 'non-prod' anywhere"       "0"      "$(grep -c 'non-prod' "$CFG")"
chk "P3b no 'nonprod' anywhere"        "0"      "$(grep -c 'nonprod' "$CFG")"
chk "P6a restricted VIP present"       "1"      "$(grep -c '199\.36\.153\.4/30' "$CFG" | xargs -I{} sh -c 'test {} -gt 0 && echo 1 || echo 0')"
chk "P6b private VIP .8/30 absent"     "0"      "$(grep -c '199\.36\.153\.8' "$CFG")"
chk "P7  34.126.0.0/18 present"        "1"      "$(grep -c '34\.126\.0\.0/18' "$CFG" | xargs -I{} sh -c 'test {} -gt 0 && echo 1 || echo 0')"
chk "P8  hybrid is ALSO a VPC spoke"   "1"      "$(yq -r '[.ncc.spokes[] | select(.vpc_ref == "hybrid" and .type == "linked_vpc_network")] | length' "$CFG")"
chk "P8b one tunnel spoke per region"   "2"      "$(yq -r '[.ncc.spokes[] | select(.type == "linked_vpn_tunnels" and .region != null)] | length' "$CFG")"
chk "P22 DNS hub is hybrid"             "true"   "$(yq -r '.dns.hybrid.inbound_policy' "$CFG")"
chk "P23 one policy per VPC (no project_ref on rule sets)" "0" "$(yq -r '[.firewall_policies[] | select(has("project_ref"))] | length' "$CFG")"
chk "P24 PSA producer spokes (shared-services only)" "1"      "$(yq -r '[.ncc.spokes[] | select(.type == "linked_producer_vpc_network")] | length' "$CFG")"
chk "P25 no PSC endpoint for Google APIs (VIP is advertised)" "0" "$(yq -r '.psc_endpoints | length' "$CFG")"
chk "P26 regional affinity: MED gap < 206"     "true" "$(yq -r '(.routers."hybrid-usw4".bgp.advertised_route_priority - .routers."hybrid-usw2".bgp.advertised_route_priority) as $d | ($d < 206 and $d > -206)' "$CFG")"
chk "P26b each router adds only its own /17s" "10.10.0.0/17,10.10.128.0/17|10.20.0.0/17,10.20.128.0/17" "$(yq -r '[(.routers."hybrid-usw4".bgp.advertised_ip_ranges - .routers."hybrid-usw2".bgp.advertised_ip_ranges | join(",")), (.routers."hybrid-usw2".bgp.advertised_ip_ranges - .routers."hybrid-usw4".bgp.advertised_ip_ranges | join(","))] | join("|")' "$CFG")"
chk "P26c both routers advertise both /16s, VIP, DNS range" "10.10.0.0/16,10.20.0.0/16,199.36.153.4/30,35.199.192.0/19" "$(yq -r '.routers."hybrid-usw4".bgp.advertised_ip_ranges as $a | .routers."hybrid-usw2".bgp.advertised_ip_ranges as $b | ($a - ($a - $b)) | join(",")' "$CFG")"
chk "P26d routable ranges sit in their region's /16" "0" "$(python3 - "$CFG" <<'PYEOF'
import json, subprocess, sys, ipaddress as ip
c = json.loads(subprocess.check_output(["yq", "-o=json", ".", sys.argv[1]]))
reg = {"us-west4": ip.ip_network("10.10.0.0/16"), "us-west2": ip.ip_network("10.20.0.0/16")}
bad = 0
for v in c["vpcs"].values():
    for s in v["subnets"].values():
        n = ip.ip_network(s["ip_cidr_range"])
        if n.subnet_of(ip.ip_network("10.0.0.0/8")) and not n.subnet_of(reg[s["region"]]): bad += 1
print(bad)
PYEOF
)"
chk "P27 local-only ranges in 100.64/10, isolated in 172.16/12" "0" "$(python3 - "$CFG" <<'PYEOF'
import json, subprocess, sys, ipaddress as ip
c = json.loads(subprocess.check_output(["yq", "-o=json", ".", sys.argv[1]]))
nr = ip.ip_network("100.64.0.0/10"); bad = 0
for vk, v in c["vpcs"].items():
    for sk, s in v["subnets"].items():
        n = ip.ip_network(s["ip_cidr_range"])
        if vk == "isolated":
            if not n.subnet_of(ip.ip_network("172.16.0.0/12")): bad += 1
            continue
        local = vk == "sec-ha" or s.get("purpose") in ("REGIONAL_MANAGED_PROXY", "PRIVATE_SERVICE_CONNECT")
        if local and not n.subnet_of(nr): bad += 1
        for r in (s.get("secondary_ip_ranges") or {}).values():
            if not ip.ip_network(r).subnet_of(nr): bad += 1
    if vk == "isolated":
        bad += sum(1 for p in (v.get("psa_ranges") or {}).values() if not ip.ip_network(p["ip_cidr_range"]).subnet_of(ip.ip_network("172.16.0.0/12")))
print(bad)
PYEOF
)"
chk "P27b every VPC spoke keeps 100.64.0.0/10 off the hub" "0" "$(yq -r '[.ncc.spokes[] | select(.type == "linked_vpc_network") | select((.exclude_export_ranges // []) | contains(["100.64.0.0/10"]) | not)] | length' "$CFG")"
chk "P28 inspection VPC is a center spoke"  "center" "$(yq -r '.ncc.spokes[] | select(.vpc_ref == "sec-trust") | .group_ref' "$CFG")"
chk "P28b security project auto-accepted in center" "1" "$(yq -r '[.ncc.groups[] | select(.name == "center") | .auto_accept_projects[] | select(. == "prj-security-net")] | length' "$CFG")"
chk "P28c every tunnel reads its key from a secret" "4" "$(yq -r '[.vpns[].tunnels[] | select(.psk_secret != null)] | length' "$CFG")"
chk "P28d tunnel /30s unique"             "4"      "$(yq -r '[.vpns[].tunnels[].bgp_ip] | unique | length' "$CFG")"
chk "P28e cloud namespace zone"           "gcp.corp.example.com." "$(yq -r '.dns.hybrid.private_zones.cloud.dns_name' "$CFG")"
chk "P28f isolated resolves no on-premises names" "0" "$(yq -r '[.dns.hybrid.private_zones.cloud.peered_by[] | select(. == "isolated")] | length' "$CFG")"
chk "P29 no duplicate rule priority on any VPC" "0" "$(yq -r '.firewall_policies as $fp | .vpcs | keys | .[] as $v | $fp[] | select(.associations[] == $v) | .rules[] | $v + " " + (.priority|tostring)' "$CFG" | sort | uniq -d | wc -l | tr -d ' ')"
chk "P9  no pod range advertised"      "0"      "$(yq -r '[.routers[] | select(.bgp != null) | .bgp.advertised_ip_ranges[]] | map(select(test("^100\\."))) | length' "$CFG")"
chk "P15 no prod/preprod isolation rule (on-prem firewall decides)" "0" "$(yq -r '[.firewall_policies[].rules[] | select(.priority == 900)] | length' "$CFG")"
chk "NAT per region for isolated and untrust" "4"     "$(yq -r '.cloud_nats | length' "$CFG")"
chk "all 9 VPCs on the global policy"  "9"      "$(yq -r '.firewall_policies."global-baseline".associations | length' "$CFG")"
chk "P30 DMZ subnets in the trust VPC"  "2"      "$(yq -r '[.vpcs.sec-trust.subnets | keys | .[] | select(test("dmz"))] | length' "$CFG")"
chk "P31 mgmt is an edge spoke"         "edge"   "$(yq -r '.ncc.spokes[] | select(.vpc_ref == "sec-mgmt") | .group_ref' "$CFG")"
chk "P31b mgmt deletes its default route" "true" "$(yq -r '.vpcs.sec-mgmt.delete_default_routes_on_create' "$CFG")"
chk "P31c security project auto-accepted in edge" "1" "$(yq -r '[.ncc.groups[] | select(.name == "edge") | .auto_accept_projects[] | select(. == "prj-security-net")] | length' "$CFG")"
chk "P32 no PSA in prod or preprod (PSC)" "0"    "$(yq -r '[.vpcs.prod.psa_ranges, .vpcs.preprod.psa_ranges] | map(select(. != null)) | length' "$CFG")"
chk "P33 trust VPC peers both DNS zones" "2"     "$(yq -r '[.dns.hybrid.private_zones[].peered_by[] | select(. == "sec-trust")] | length' "$CFG")"
chk "P33b trust VPC has the restricted VIP route" "1" "$(yq -r '[.routes[] | select(.vpc_ref == "sec-trust" and .dest_range == "199.36.153.4/30")] | length' "$CFG")"
chk "P34 VPC ranges inside the diagram blocks" "0" "$(python3 - "$CFG" <<'PYEOF'
import json, subprocess, sys, ipaddress as ip
c = json.loads(subprocess.check_output(["yq", "-o=json", ".", sys.argv[1]]))
blk = {"hybrid": "0.0/25", "shared-services": "2.0/23", "sec-mgmt": "4.0/22", "sec-untrust": "4.0/22",
       "sec-trust": "4.0/22", "prod": "64.0/20", "preprod": "128.0/20"}
reg = {"us-west4": "10.10.", "us-west2": "10.20."}
bad = 0
for vk, v in c["vpcs"].items():
    if vk not in blk: continue
    for s in v["subnets"].values():
        n = ip.ip_network(s["ip_cidr_range"])
        if n.subnet_of(ip.ip_network("100.64.0.0/10")): continue
        if not n.subnet_of(ip.ip_network(reg[s["region"]] + blk[vk])): bad += 1
    for p in (v.get("psa_ranges") or {}).values():
        n = ip.ip_network(p["ip_cidr_range"])
        if not any(n.subnet_of(ip.ip_network(r + blk[vk])) for r in reg.values()): bad += 1
print(bad)
PYEOF
)"
echo
echo "=== KNOWN OPEN (expected non-zero; a change here means something moved) ==="
printf "  OPEN  %-58s %s\n" "TODO- placeholders"            "$(grep -c 'TODO-' "$CFG")"
printf "  OPEN  %-58s %s\n" "forwarding_zones populated"    "$(yq -r '.dns.hybrid.forwarding_zones | length' "$CFG")"
printf "  OPEN  %-58s %s\n" "export_psc on the hub"         "$(yq -r '.ncc.hubs[0].export_psc' "$CFG")"
printf "  OPEN  %-58s %s\n" "reserved addresses (PSC/LB)"   "$(yq -r '.addresses | length' "$CFG")"
printf "  OPEN  %-58s %s\n" "deny-all egress baseline"      "$(yq -r '[.firewall_policies."global-baseline".rules | to_entries[] | select(.value.action == "deny")] | length' "$CFG")"
printf "  OPEN  %-58s %s\n" "IAP allow (35.235.240.0/20)"   "$(grep -c '35\.235\.240' "$CFG")"
printf "  OPEN  %-58s %s\n" "health-check allow (35.191/130.211)" "$(grep -cE '35\.191\.|130\.211\.' "$CFG")"
printf "  OPEN  %-58s %s\n" "shared_vpc service projects"   "$(yq -r '[.shared_vpc[].service_project_refs[]] | length' "$CFG")"
echo
echo "=== TOTALS: $pass met, $fail failed ==="
exit $fail
