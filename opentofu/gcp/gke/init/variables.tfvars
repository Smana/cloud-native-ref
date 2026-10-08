env        = "dev"
project_id = "ogenki-435905"
region     = "europe-west4"

cluster_name    = "gcp-0"
release_channel = "REGULAR"

custom_role_suffix = "_v3"

# Slice 4 must pin the SAME image type on every ComputeClass.
node_image_type   = "COS_CONTAINERD"
node_machine_type = "e2-standard-4"
node_count        = 2
node_max_count    = 3

# The cluster-wide ceiling counts EVERY node, the fixed pools included, so it
# must cover their maxima with room left for NAP. Refused scale-ups read
# `NotTriggerScaleUp: max cluster cpu limit reached`. A ceiling costs nothing
# until nodes exist, and all of them are spot.
#   vCPU:   static 3 x 4  + agents-gvisor 2 x 8  + L4 2 x 4  = 36 of 48  -> 12 for CPU classes
#   memory: static 3 x 16 + agents-gvisor 2 x 32 + L4 2 x 16 = 144 of 192 -> 48 GiB for CPU classes
# (L4: main.tf's gpu_resources maximum, one per g2-standard-4.)
# test-gcp-agents-pool.sh fails if these fixed maxima outgrow the ceiling.
autoscaling_max_cpu_cores = 48
autoscaling_max_memory_gb = 192

tags = {
  project = "cloud-native-ref"
  owner   = "smana"
  cloud   = "gcp"
}
