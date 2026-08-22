env            = "dev"
project_id     = "ogenki-435905"
project_number = "323586397743"
region         = "europe-west4"
zone           = "europe-west4-a"

cluster_name    = "gcp-mycluster-0"
release_channel = "REGULAR"

# Slice 4 must pin the SAME image type on every ComputeClass.
node_image_type   = "COS_CONTAINERD"
node_machine_type = "e2-standard-4"
node_count        = 2
node_max_count    = 3

tags = {
  project = "cloud-native-ref"
  owner   = "smana"
  cloud   = "gcp"
}
