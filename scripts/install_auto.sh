#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"
DISK=""
EFI_SIZE="1024"
ROOTPASS=""
H_NAME="artix"
LOCALE="en_US.UTF-8"
TIMEZONE="Europe/Berlin"
INIT_SYS=""

check_uefi() {
    [[ ! -d /sys/firmware/efi ]] && { echo "[ERROR] UEFI required."; exit 1; }
}

detect_init() {
    if [ -f /run/runit/runsvdir/current ]; then INIT_SYS="runit"
    elif [ -d /run/openrc ]; then INIT_SYS="openrc"
    elif [ -d /run/dinit ]; then INIT_SYS="dinit"
    elif [ -f /run/s6/services ]; then INIT_SYS="s6"
    else INIT_SYS="openrc"; fi
    echo "[*] Detected live init: $INIT_SYS"
}

wipe_disk() {
    echo "[*] Wiping partition table on $DISK..."
    wipefs -a "$DISK"
    sgdisk --zap-all "$DISK"
}

partition_disk() {
    echo "[*] Creating GPT partitions..."
    # Job: Create EFI (ef00) and Root (8300)
    sgdisk -n 1:0:+${EFI_SIZE}M -t 1:ef00 "$DISK"
    sgdisk -n 2:0:0           -t 2:8300 "$DISK"
}

format_partitions() {
    echo "[*] Formatting filesystems..."
    local efi_p="${DISK}1"; local root_p="${DISK}2"
    [[ "$DISK" =~ "nvme" ]] && { efi_p="${DISK}p1"; root_p="${DISK}p2"; }

    mkfs.fat -F32 "$efi_p"
    mkfs.ext4 -F "$root_p"
}

mount_partitions() {
    echo "[*] Mounting partitions to /mnt..."
    local efi_p="${DISK}1"; local root_p="${DISK}2"
    [[ "$DISK" =~ "nvme" ]] && { efi_p="${DISK}p1"; root_p="${DISK}p2"; }

    mount "$root_p" /mnt
    mount --mkdir "$efi_p" /mnt/boot/efi
}

run_basestrap() {
    echo "[*] Running basestrap (Minimal core only)..."
    # We only install essentials for a bootable CLI system
    basestrap /mnt base base-devel linux linux-firmware \
        "$INIT_SYS" elogind-"$INIT_SYS" grub efibootmgr os-prober \
        dhcpcd dhcpcd-"$INIT_SYS" iwd iwd-"$INIT_SYS" nano artix-archlinux-support
}

configure_base_system() {
    echo "[*] Generating fstab..."
    fstabgen -U /mnt >> /mnt/etc/fstab

    echo "[*] Configuring system through chroot..."
    artix-chroot /mnt /bin/bash <<EOF
# Localization & Time
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "$LOCALE UTF-8" >> /etc/locale.gen && locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "$H_NAME" > /etc/hostname

# Root Auth
echo "root:$ROOTPASS" | chpasswd

# Bootloader setup 
echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARTIX --recheck --removable
grub-mkconfig -o /boot/grub/grub.cfg

# Enable networking
case "$INIT_SYS" in
    openrc) rc-update add dhcpcd default; rc-update add iwd default ;;
    runit)  ln -s /etc/runit/sv/dhcpcd /etc/runit/runsvdir/default/; ln -s /etc/runit/sv/iwd /etc/runit/runsvdir/default/ ;;
    dinit)  mkdir -p /etc/dinit.d/boot.d; ln -s ../dhcpcd /etc/dinit.d/boot.d/; ln -s ../iwd /etc/dinit.d/boot.d/ ;;
esac
EOF
}

setup_handoff() {
    echo "[*] Preparing post-install wizard..."
    if [ -f "$SCRIPT_DIR/../firstboot.sh" ]; then
        install -Dm755 "$SCRIPT_DIR/../firstboot.sh" /mnt/usr/local/bin/firstboot.sh
        install -Dm755 "$SCRIPT_DIR/../firstboot_trigger.sh" /mnt/etc/profile.d/firstboot.sh
    elif [ -f "$SCRIPT_DIR/firstboot.sh" ]; then
        install -Dm755 "$SCRIPT_DIR/firstboot.sh" /mnt/usr/local/bin/firstboot.sh
        install -Dm755 "$SCRIPT_DIR/firstboot_trigger.sh" /mnt/etc/profile.d/firstboot.sh
    else
        echo "[WARNING] Post-install scripts not found! Skipping handoff."
    fi
}

main() {
    check_uefi
    detect_init
    
    lsblk -dpno NAME,SIZE,MODEL | grep -v loop
    read -rp "Enter target disk (e.g. /dev/sda): " DISK
    [[ ! -b "$DISK" ]] && { echo "Invalid device"; exit 1; }
    
    read -rsp "Set temporary root password: " ROOTPASS; echo

    wipe_disk
    partition_disk
    format_partitions
    mount_partitions
    run_basestrap
    configure_base_system
    copy_scripts

    umount -R /mnt
    echo "[✓] Core installation finished. Reboot to launch the wizard."
}

main
