# Everything else is left on its defaults in variables.tf, which carry the
# project's real values (europe-west4, priv.gcp.ogenki.io, the Secret Manager
# entry names the ceremony and init script create).
project_id = "ogenki-435905"

# The same apps as AWS (opentofu/aws/openbao/management/variables.tfvars), so a
# persona behaves identically on either cloud's OpenBao.
secret_owning_apps = ["app-wizard", "image-gallery"]
