# project_id has no default (see variables.tf) -- it must always be supplied.
# Every other variable is left on its default: region/zone/env match the rest
# of the GCP stacks, machine_type/data_disk_size_gb/server_cert_secret_name/
# openbao_data_path/openbao_version are the scaffolding defaults from the
# design doc (openbao_version tracks the AWS pin -- see variables.tf).
project_id = "ogenki-435905"
