#!/bin/bash
set -euo pipefail

#################
# CONFIG
#################

LOCALE="en_US.UTF-8"
TIMEZONE="Europe/Berlin"
H_NAME="artix"

DISK=""
WITH_HOME="n"

EFI_SIZE="1024"

ROOT_SIZE=""
SWAP_SIZE=""
HOME_SIZE=""

EFI_PART=""
ROOT_PART=""
SWAP_PART=""
HOME_PART=""

ROOTPASS=""
ROOTPASS_CONFIRM=""

#################
# UTILS
#################

pause() {
    read -rp "Press ENTER to continue..."
}

hr() {
    echo "---------------------------------------"
}

#################
# CHECKS
#################

check_efi() {
    [[ -d /sys/firmware/efi ]] || {
        echo "[ERROR] EFI mode required."
        exit 1
    }
}

ensure_tools() {
    echo "Installing required tools..."
    pacman -Sy --noconfirm gptfdisk parted
}

ask_passwords() {
    echo
    echo "[!] Root password setup"
    hr

    read -rsp "Enter root password: " ROOTPASS
    echo
    read -rsp "Confirm root password: " ROOTPASS_CONFIRM
    echo

    [[ "$ROOTPASS" == "$ROOTPASS_CONFIRM" ]] || {
        echo "[ERROR] Passwords do not match."
        exit 1
    }

    if [[ -z "$ROOTPASS" ]]; then
        echo "[ERROR] Empty password not allowed."
        exit 1
    fi
}

#################
# DISK SELECTION
#################

select_disk() {
    echo "[0] Available disks:"
    hr
    lsblk -dpno NAME,SIZE,MODEL | grep -E "/dev/(sd|vd|nvme)"
    hr

    read -rp "Enter target disk (e.g. /dev/vda): " DISK

    if [[ ! -b "$DISK" ]]; then
        echo "[ERROR] Invalid disk."
        exit 1
    fi

    echo "[✓] Selected disk: $DISK"
}

#################
# CONFIRMATION
#################

confirm_wipe() {
    echo
    echo "[WARNING] ALL DATA ON $DISK WILL BE LOST!"
    hr

    read -rp "Use /home partition? (y/n): " WITH_HOME
    [[ "$WITH_HOME" == "y" || "$WITH_HOME" == "n" ]] || exit 1

    echo
    read -rp "Type YES to continue: " ANS
    [[ "$ANS" == "YES" ]] || exit 1
}

#################
# SIZE INPUT
#################

ask_sizes() {
    echo
    echo "[1] Partition sizing (GB)"
    hr

    local disk_gb usable_gb
    disk_gb=$(disk_size_gb)

    local overhead=1
    local efi=1

    usable_gb=$((disk_gb - overhead - efi))

    echo "[INFO] Disk size: ${disk_gb} GB"
    echo "[INFO] EFI partition: ${efi} GB"
    echo "[INFO] Reserved overhead: ${overhead} GB"
    echo "[INFO] Usable space: ${usable_gb} GB"
    echo

    while true; do
        read -rp "ROOT size (GB): " ROOT_SIZE
        read -rp "SWAP size (GB): " SWAP_SIZE

        if [[ "$WITH_HOME" == "y" ]]; then
            read -rp "HOME size (GB or 'max'): " HOME_SIZE
        fi

        if validate_sizes; then
            break
        else
            echo
            echo "[!] Invalid sizes, please try again."
            hr
        fi
    done
}

disk_size_gb() {
    lsblk -bno SIZE "$DISK" | awk '{printf "%d", $1/1024/1024/1024}'
}

validate_sizes() {
    local disk_gb usable_gb used

    disk_gb=$(disk_size_gb)

    local overhead=1
    local efi=1

    usable_gb=$((disk_gb - overhead - efi))

    # numeric validation
    [[ "$ROOT_SIZE" =~ ^[0-9]+$ ]] || { echo "[ERROR] ROOT must be a number"; return 1; }
    [[ "$SWAP_SIZE" =~ ^[0-9]+$ ]] || { echo "[ERROR] SWAP must be a number"; return 1; }

    used=$((ROOT_SIZE + SWAP_SIZE))

    if [[ "$WITH_HOME" == "y" ]]; then
        if [[ "$HOME_SIZE" != "max" ]]; then
            [[ "$HOME_SIZE" =~ ^[0-9]+$ ]] || { echo "[ERROR] HOME must be a number or 'max'"; return 1; }
            used=$((used + HOME_SIZE))
        fi
    fi

    if (( used > usable_gb )); then
        echo "[ERROR] Not enough space."
        echo "Used: $used GB / Usable: $usable_gb GB"
        return 1
    fi

    return 0
}
#################
# DISK PREP
#################

prepare_disk() {
    echo "[2] Partitioning disk..."
    hr

    wipefs -a "$DISK"
    sgdisk --zap-all "$DISK"

    ROOT_MB=$((ROOT_SIZE * 1024))
    SWAP_MB=$((SWAP_SIZE * 1024))

    # EFI
    sgdisk -n 1:0:+${EFI_SIZE}M -t 1:ef00 "$DISK"

    # ROOT
    sgdisk -n 2:0:+${ROOT_MB}M -t 2:8300 "$DISK"

    if [[ "$WITH_HOME" == "y" ]]; then
        # HOME (directly after root)
        if [[ "$HOME_SIZE" == "max" ]]; then
            sgdisk -n 3:0:0 -t 3:8300 "$DISK"
        else
            HOME_MB=$((HOME_SIZE * 1024))
            sgdisk -n 3:0:+${HOME_MB}M -t 3:8300 "$DISK"
        fi

        # SWAP last
        sgdisk -n 4:0:+${SWAP_MB}M -t 4:8200 "$DISK"
    else
        # SWAP third
        sgdisk -n 3:0:+${SWAP_MB}M -t 3:8200 "$DISK"
    fi

    partprobe "$DISK"
    sleep 2

    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
    SWAP_PART="${DISK}3"

    if [[ "$WITH_HOME" == "y" ]]; then
        HOME_PART="${DISK}3"
        SWAP_PART="${DISK}4"
    fi
}

#################
# FORMAT
#################

format_partitions() {
    echo "[3] Formatting..."
    hr

    mkfs.fat -F32 "$EFI_PART"
    mkfs.ext4 "$ROOT_PART"
    mkswap "$SWAP_PART"

    if [[ "$WITH_HOME" == "y" ]]; then
    	mkfs.ext4 "$HOME_PART"
    fi
}

#################
# MOUNT
#################

mount_system() {
    echo "[4] Mounting..."
    hr

    mount "$ROOT_PART" /mnt
    mount --mkdir "$EFI_PART" /mnt/boot/efi
    swapon "$SWAP_PART"

    if [[ "$WITH_HOME" == "y" ]]; then
        mount --mkdir "$HOME_PART" /mnt/home
    fi
}

#################
# BASE INSTALL
#################

install_base() {
    echo "[5] Installing base system..."
    hr

    basestrap /mnt \
        base base-devel linux linux-firmware \
        runit elogind-runit \
        grub efibootmgr \
        fastfetch nano \
        dhcpcd dhcpcd-runit \
        iwd iwd-runit
}

gen_fstab() {
    echo "[6] Generating filesystem table..."
    fstabgen -U /mnt >>/mnt/etc/fstab
}

#################
# CHROOT CONFIG
#################

configure_system() {
    echo "[7] System config (chroot)..."
    hr

    read -rp "Timezone (e.g. Europe/Berlin [default]): " TIMEZONE

    artix-chroot /mnt /bin/bash <<EOF
set -e

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen

echo "LANG=$LOCALE" > /etc/locale.conf

echo "$H_NAME" > /etc/hostname

echo "127.0.1.1        $H_NAME.localdomain        $H_NAME" >> /etc/hosts

grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=ARTIX \
    --recheck

grub-mkconfig -o /boot/grub/grub.cfg

echo "root:$ROOTPASS" | chpasswd

EOF
}

#################
# CLEANUP
#################

cleanup() {
    echo "[8] Cleaning up..."
    umount -R /mnt || true
}

#################
# MAIN FLOW
#################

main() {
    check_efi
    ensure_tools

    echo "=== ARTIX EFI INSTALLER ==="
    pause

    ask_passwords

    select_disk
    confirm_wipe
    ask_sizes
    validate_sizes

    prepare_disk
    format_partitions
    mount_system
    install_base
    gen_fstab
    configure_system
    cleanup

    echo
    echo "[✓] INSTALL COMPLETE"
    echo "You may reboot now."
}

main
