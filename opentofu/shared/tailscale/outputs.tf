# No outputs.
#
# Nothing downstream reads this stack via remote state on purpose: the CIDRs
# that feed tailscale_acl.this flow in as the advertised_routes *variable*
# (see variables.tf), precisely so that opentofu/aws/network and
# opentofu/gcp/network never have to depend on this stack's state to depend on
# each other's inputs -- that would be the circular dependency this stack
# exists to avoid. The three resources here (ACL, DNS nameservers, DNS search
# paths) are tailnet-wide singletons with no id any other stack needs.
