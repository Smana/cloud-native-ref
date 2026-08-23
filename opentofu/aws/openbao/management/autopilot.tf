# Raft autopilot — dead server cleanup
# ------------------------------------
# Autopilot runs by default in OpenBao, but dead server cleanup does NOT: it
# "must be explicitly activated"
# (openbao.org/docs/concepts/integrated-storage/autopilot). Without it a node
# that goes away stays in the raft voter set forever.
#
# That is not a corner case on this cluster. The ha-mode ASG is 95% spot with
# instance refresh enabled, and the raft node_id is the EC2 instance id
# (`node_id = "$INSTANCE_ID"` in cluster/scripts/startup_script.sh), so every
# replacement joins under a new id and the old one is simply left behind.
#
# Measured 2026-08-19: raft listed six voters against five live instances.
# Quorum is computed over the voter set, not over live nodes, so the bar moved
# from 3-of-5 to 4-of-6 and vault_autopilot_failure_tolerance halved from 2 to
# 1 — the cluster silently lost half the redundancy it was sized for, with
# nothing failing and nothing alerting.
#
# min_quorum is the guard on the cleanup itself: autopilot will not remove
# servers below it, so a burst of reclamations cannot cascade into losing
# quorum. 3 is the majority of the five-node ha ASG, and OpenBao rejects values
# below 3 when cleanup is enabled.
#
# Note for recovery: a server autopilot removes must be REINITIALISED before it
# can rejoin. Harmless here — ASG replacements are always fresh instances.
resource "vault_raft_autopilot" "this" {
  count = var.mode == "ha" ? 1 : 0

  cleanup_dead_servers = true
  min_quorum           = 3

  # Long enough that a node being replaced, or a slow boot, is not mistaken for
  # a dead one; short enough that a reclaimed spot instance does not distort
  # quorum for a working day.
  dead_server_last_contact_threshold = "30m"
}
