#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"
LOCALE="en_US.UTF-8"
TIMEZONE="Europe/Berlin"
H_NAME="artix"
ROOTPASS=""
INIT_SYS=""

check_uefi() {
    [[ ! -d /sys/firmware/efi ]] && { echo "[ERROR] UEFI required."; exit 1; }
}

detect_live_init() {
    if [ -f /run/runit/runsvdir/current ]; then INIT_SYS="runit"
    elif [ -d /run/openrc ]; then INIT_SYS="openrc"
    elif [ -d /run/dinit ]; then INIT_SYS="dinit"
    elif [ -f /run/s6/services ]; then INIT_SYS="s6"
    else INIT_SYS="openrc"; fi
    echo "[*] Detected live init: $INIT_SYS"
}

verify_mounts() {
    echo "[*] Verifying manual mount points..."
    if ! findmnt /mnt >/dev/null; then
        echo "[ERROR] Nothing mounted on /mnt. Please mount your Root partition."
        exit 1
    fi
    if ! findmnt /mnt/boot/efi >/dev/null; then
        echo "[ERROR] Nothing mounted on /mnt/boot/efi. Please mount your EFI partition."
        exit 1
    fi
    echo "[✓] Mount points verified."
}

run_basestrap() {
    echo "[*] Running basestrap (Minimal core only)..."
    local ucode="amd-ucode"
    grep -q "GenuineIntel" /proc/cpuinfo && ucode="intel-ucode"
    basestrap /mnt base base-devel linux linux-firmware "$ucode" \
        "$INIT_SYS" elogind-"$INIT_SYS" grub efibootmgr os-prober \
        dhcpcd dhcpcd-"$INIT_SYS" iwd iwd-"$INIT_SYS" nano artix-archlinux-support
}

configure_base_system() {
    echo "[*] Generating fstab..."
    fstabgen -U /mnt >> /mnt/etc/fstab

    echo "[*] Entering chroot for minimal setup..."
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

# Pacman Optimization
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf

# Essential Networking
case "$INIT_SYS" in
    openrc) rc-update add dhcpcd default; rc-update add iwd default ;;
    runit)  ln -s /etc/runit/sv/dhcpcd /etc/runit/runsvdir/default/; ln -s /etc/runit/sv/iwd /etc/runit/runsvdir/default/ ;;
    dinit)  mkdir -p /etc/dinit.d/boot.d; ln -s ../dhcpcd /etc/dinit.d/boot.d/; ln -s ../iwd /etc/dinit.d/boot.d/ ;;
    s6)     s6-rc-bundle-update add default dhcpcd; s6-rc-bundle-update add default iwd ;;
esac
EOF
}

copy_scripts() {
    echo "[*] Deploying post-install wizard..."
    if [ -f "$SCRIPT_DIR/../firstboot.sh" ]; then
        install -Dm755 "$SCRIPT_DIR/../firstboot.sh" /mnt/usr/local/bin/firstboot.sh
        install -Dm755 "$SCRIPT_DIR/../firstboot_trigger.sh" /mnt/etc/profile.d/firstboot.sh
    elif [ -f "$SCRIPT_DIR/firstboot.sh" ]; then
        install -Dm755 "$SCRIPT_DIR/firstboot.sh" /mnt/usr/local/bin/firstboot.sh
        install -Dm755 "$SCRIPT_DIR/firstboot_trigger.sh" /mnt/etc/profile.d/firstboot.sh
    else
        echo "[WARNING] Post-install scripts not found! Wizard skipped."
    fi
}

main() {
    check_uefi
    detect_live_init
    verify_mounts
    
    read -rsp "Set temporary root password: " ROOTPASS; echo

    run_basestrap
    configure_base_system
    copy_scripts

    umount -R /mnt
    echo "[✓] MANUAL INSTALLATION COMPLETE! Reboot and log in to start the setup wizard."
}

main
