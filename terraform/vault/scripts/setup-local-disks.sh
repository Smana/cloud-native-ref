#!/usr/bin/env bash

# Based on https://github.com/awslabs/amazon-eks-ami

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

create_systemd_mount_unit() {
    local dev="$1"
    local mount_point="$2"
    local unit_name
    unit_name="$(systemd-escape --path --suffix=mount "$mount_point")"
    mkdir -p "$mount_point"
    cat > "/etc/systemd/system/$${unit_name}" << EOF
[Unit]
Description=Mount at $mount_point
[Mount]
What=$dev
Where=$mount_point
Type=xfs
Options=defaults,noatime
[Install]
WantedBy=multi-user.target
EOF
    systemd-analyze verify "$unit_name"
    systemctl enable "$unit_name" --now
}

vault_storage_mount() {
  idx=1
  for dev in "$${EPHEMERAL_DISKS[@]}"; do
    if [[ -z "$(lsblk "$${dev}" -o fstype --noheadings)" ]]; then
      mkfs.xfs -l su=8b "$${dev}"
    fi
    if [[ ! -z "$(lsblk "$${dev}" -o MOUNTPOINT --noheadings)" ]]; then
      echo "$${dev} is already mounted."
      continue
    fi
    local mount_point="$${MNT_DIR}/$${idx}"
    local mount_unit_name="$(systemd-escape --path --suffix=mount "$${mount_point}")"
    mkdir -p "$${mount_point}"
    cat > "/etc/systemd/system/$${mount_unit_name}" << EOF
    [Unit]
    Description=Mount EC2 Instance Store NVMe disk $${idx}
    [Mount]
    What=$${dev}
    Where=$${mount_point}
    Type=xfs
    Options=defaults,noatime
    [Install]
    WantedBy=multi-user.target
EOF
    systemd-analyze verify "$${mount_unit_name}"
    systemctl enable "$${mount_unit_name}" --now
    idx=$((idx + 1))
  done
}

MNT_DIR="/opt/vault/data"

check_command mdadm
check_command systemd-analyze
check_command blkid

disks=($(find -L /dev/disk/by-id/ -xtype l -name '*NVMe_Instance_Storage_*'))
if [[ $${#disks[@]} -eq 0 ]]; then
    echo "No ephemeral disks found, skipping disk setup"
    exit 0
fi

if [[ $(id --user) -ne 0 ]]; then
    echo "Must be run as root"
    exit 1
fi

EPHEMERAL_DISKS=($(realpath "$${disks[@]}" | sort -u))

vault_storage_mount
echo "Successfully setup volume consisting of $${EPHEMERAL_DISKS[*]}"
