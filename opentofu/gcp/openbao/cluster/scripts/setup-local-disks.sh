#!/usr/bin/env bash
# Formats and mounts the OpenBao data disk. Rendered into the instance's
# `metadata_startup_script` (compute.tf), concatenated BEFORE startup-script.sh
# -- the data disk has to be mounted before OpenBao is configured to write its
# storage there. Runs on every boot, not only the first: the idempotency
# checks below (skip mkfs if a filesystem already exists, `systemctl enable
# --now` is itself idempotent) are what make that safe.
#
# Ported from
# opentofu/aws/openbao/cluster/scripts/setup-local-disks.sh, which discovers
# and RAID-0s ephemeral NVMe instance store via a udev alias glob, because AWS
# gives no stable, predictable device path for instance-store disks. GCP does:
# a persistent disk attached with a fixed `device_name` (compute.tf sets
# device_name = "openbao-data") always appears at
# /dev/disk/by-id/google-<device_name>. That removes the whole discovery/RAID
# step -- there is exactly one disk, at a known path, every boot.

set -o errexit
set -o pipefail
set -o nounset

err_report() {
  echo "Error occurred on line $1: $BASH_COMMAND"
}
trap 'err_report $LINENO' ERR

check_command() {
  local cmd=$1
  if ! command -v "$cmd" &> /dev/null; then
    echo "Command not found: $cmd"
    exit 1
  fi
}

check_command mkfs.xfs
check_command systemd-analyze
check_command blkid
check_command lsblk

DATA_DISK="/dev/disk/by-id/google-openbao-data"
MNT_DIR="${openbao_data_path}"

if [[ ! -e "$DATA_DISK" ]]; then
  echo "Data disk $DATA_DISK not found, skipping disk setup"
  exit 0
fi

if [[ $(id --user) -ne 0 ]]; then
  echo "Must be run as root"
  exit 1
fi

# Idempotent: only format a disk that has no filesystem yet. A re-run after
# the unit is already mounted must not reformat a disk holding OpenBao's raft
# or file storage.
if [[ -z $(lsblk "$DATA_DISK" -o fstype --noheadings) ]]; then
  mkfs.xfs "$DATA_DISK"
fi

mkdir -p "$MNT_DIR"

DEV_UUID=$(blkid -s UUID -o value "$DATA_DISK")
UNIT_NAME="$(systemd-escape --path --suffix=mount "$MNT_DIR")"

cat > "/etc/systemd/system/$UNIT_NAME" << EOF
[Unit]
Description=Mount OpenBao data disk at $MNT_DIR

[Mount]
What=UUID=$DEV_UUID
Where=$MNT_DIR
Type=xfs
Options=defaults,noatime

[Install]
WantedBy=multi-user.target
EOF

systemd-analyze verify "$UNIT_NAME"
systemctl enable "$UNIT_NAME" --now

echo "Successfully mounted $DATA_DISK at $MNT_DIR"
