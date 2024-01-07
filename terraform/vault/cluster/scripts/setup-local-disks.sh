#!/usr/bin/env bash
# Based on https://github.com/awslabs/amazon-eks-ami
set -o errexit
set -o pipefail
set -o nounset

if ! curl -s http://169.254.169.254/latest/meta-data/instance-id > /dev/null; then
  echo "This script must be run on an EC2 instance."
  exit 1
fi
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

setup_raid0() {
    local md_name="vault"
    local md_device="/dev/md/$${md_name}"
    local md_config="/.aws/mdadm.conf"
    local array_mount_point="$MNT_DIR"
    mkdir -p "$(dirname "$md_config")"

    if [[ ! -s "$md_config" ]]; then
        mdadm --create --force --verbose \
              "$md_device" \
              --level=0 \
              --name="$md_name" \
              --raid-devices="$${#EPHEMERAL_DISKS[@]}" \
              "$${EPHEMERAL_DISKS[@]}"
        while [ -n "$(mdadm --detail "$md_device" | grep -ioE 'State :.*resyncing')" ]; do
            echo "Raid is resyncing..."
            sleep 1
        done
        mdadm --detail --scan > "$md_config"
    fi

    local current_md_device
    current_md_device=$(find /dev/md/ -type l -regex ".*/$${md_name}_?[0-9a-z]*$" | tail -n1)
    [[ -n $current_md_device ]] && md_device=$current_md_device

    if [[ -z $(lsblk "$md_device" -o fstype --noheadings) ]]; then
        mkfs.xfs -l su=8b "$md_device"
    fi

    mkdir -p "$array_mount_point"
    local dev_uuid
    dev_uuid=$(blkid -s UUID -o value "$md_device")
    create_systemd_mount_unit "UUID=$dev_uuid" "$array_mount_point"
}

MNT_DIR="/opt/vault/data"
mkdir -p $MNT_DIR

check_command mdadm
check_command systemd-analyze
check_command blkid

disks=($(find -L /dev/disk/by-id/ -xtype l -name '*NVMe_Instance_Storage_*'))
if [[ $${#disks[@]} -eq 0 ]]; then
    echo "No ephemeral disks found, skipping disk setup"
else
  if [[ $(id --user) -ne 0 ]]; then
      echo "Must be run as root"
      exit 1
  fi
  EPHEMERAL_DISKS=($(realpath "$${disks[@]}" | sort -u))

  setup_raid0
  echo "Successfully setup RAID-0 consisting of $${EPHEMERAL_DISKS[*]}"
fi
