# Everything is on its defaults in variables.tf, which carry the project's real
# values. Present and TRACKED because a stack whose tfvars is gitignored cannot
# be deployed from a clean checkout -- see the defect fixed in #1833.
gcp_project_id = "ogenki-435905"

# Filled in Task 16 from `tofu output` in opentofu/gcp/openbao/lineage. Empty
# until then, which skips the two Google-identity roles.
gcp_openbao_standby_sa_unique_id = "110583515827251510802"
gcp_transfer_agent_subject_id    = "103642011123339318159"
