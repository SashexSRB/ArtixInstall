#!/usr/bin/env bash
set -euo pipefail;

EFI_SIZE="1024";
DISK="";
ROOTPASS="";
INIT="";
REMOVABLE_FLAG="";
USE_LUKS=1;
BOOTLOADER="grub";
MAPPER_NAME="cryptroot";
FS_TYPE="btrfs";

SELF_PATH="$(readlink -f "${BASH_SOURCE}")";
SCRIPT_DIR="${SELF_PATH%/*}";

function _error_exit {
    local reason="${1}";
    printf "%b%s%b\n" "\e[1;31m" "${reason^}" "\e[m" >&2;
    exit 1;
}

function _ask {
    local question="${1}";
    local default="${2}";
    local options response;
    [[ "${default,,}" == "y" ]] && options="Y/n" || options="y/N";
    printf -v question "%s [%s]: " "${1}" "${options}";
    read -r -p "${question}" response </dev/tty;
    case "${response,,}" in
        "y"|"yes") return 0 ;;
        "n"|"no")  return 1 ;;
        *) [[ "${default,,}" == "y" ]] && return 0 || return 1 ;;
    esac
}

function _ensure_tools {
    printf "[*] Updating database and installing tools...\n";
    pacman -Sy --noconfirm gptfdisk util-linux cryptsetup btrfs-progs e2fsprogs efibootmgr;
}

function _choose_fs {
    printf "1) BTRFS (Subvolumes)  2) EXT4 (The Classic)\n";
    printf "Filesystem: "; read -r fc </dev/tty;
    [[ "${fc}" == "2" ]] && FS_TYPE="ext4" || FS_TYPE="btrfs";
}

function _choose_init {
    printf "1) openrc  2) runit  3) dinit  4) s6\n";
    printf "Init: "; read -r ic </dev/tty;
    case "${ic}" in
        1) INIT="openrc" ;;
        2) INIT="runit" ;;
        3) INIT="dinit" ;;
        4) INIT="s6" ;;
        *) INIT="openrc" ;;
    esac
}

function _choose_bootloader {
    printf "1) GRUB (Standard)  2) rEFInd (Graphical/Auto-detect)\n";
    printf "Bootloader: "; read -r bc </dev/tty;
    [[ "${bc}" == "2" ]] && BOOTLOADER="refind" || BOOTLOADER="grub";
}

function _setup_encryption {
    local enable_luks=1;
    _ask "Enable LUKS Encryption?" "n" && enable_luks=0 || enable_luks=1;
    if [[ "${enable_luks}" -eq 0 ]]; then
        USE_LUKS=0
        exec </dev/tty
        printf "LUKS Passphrase: "
        read -rs LUKS_PASS
        echo
        printf "Confirm Passphrase: "
        read -rs LUKS_PASS_CONFIRM
        echo
        if [[ "${LUKS_PASS}" != "${LUKS_PASS_CONFIRM}" ]]; then
            _error_exit "passwords do not match"
        fi
    fi
}

function _ask_info {
    lsblk -dpno NAME,SIZE,MODEL | grep -E "/dev/(sd|vd|nvme|mmcblk)" || true;
    printf "Target Disk: "; read -r DISK </dev/tty;
    [[ ! -b "${DISK}" ]] && _error_exit "invalid device";
    local confirm_destroy=1;
    _ask "Destroy all data on ${DISK}?" "n" && confirm_destroy=0 || confirm_destroy=1;
    [[ "${confirm_destroy}" -ne 0 ]] && _error_exit "aborted";
    printf "Root password: "; read -rs ROOTPASS </dev/tty; echo;
    if _ask "External/removable drive?" "n"; then REMOVABLE_FLAG="--removable"; fi
    echo ""
}

function _partition_storage {
    printf "[*] Partitioning storage (%s)...\n" "${FS_TYPE^^}";

    umount -R /mnt 2>/dev/null || true
    cryptsetup close "${MAPPER_NAME}" 2>/dev/null || true
    udevadm settle

    wipefs -a "${DISK}";
    sgdisk --zap-all "${DISK}";
    sgdisk -n 1:0:+${EFI_SIZE}M -t 1:ef00 "${DISK}";
    sgdisk -n 2:0:0           -t 2:8300 "${DISK}";

    printf "[*] Refreshing partition table...\n";
    blockdev --rereadpt "${DISK}" || true;
    udevadm settle;
    
    local efi_p root_p target_dev;

    if [[ "${DISK}" =~ (nvme|mmcblk|loop) ]]; then
        efi_p="${DISK}p1";
        root_p="${DISK}p2";
    else
        efi_p="${DISK}1";
        root_p="${DISK}2";
    fi

    [[ ! -b "${efi_p}" ]] && _error_exit "EFI partition (${efi_p}) not found! Kernel lag?";

    printf "[*] Formatting EFI: %s\n" "${efi_p}";
    mkfs.fat -F32 "${efi_p}";
    target_dev="${root_p}";

    if [[ "${USE_LUKS}" -eq 0 ]]; then
        printf "[*] Initializing LUKS on %s\n" "${root_p}";
        printf "%s" "${LUKS_PASS}" | cryptsetup luksFormat "${root_p}" -;
        printf "%s" "${LUKS_PASS}" | cryptsetup open "${root_p}" "${MAPPER_NAME}" -;
        target_dev="/dev/mapper/${MAPPER_NAME}";
    fi

    if [[ "${FS_TYPE}" == "btrfs" ]]; then
        printf "[*] Creating BTRFS subvolumes on %s\n" "${target_dev}";
        mkfs.btrfs -f "${target_dev}";
        mount "${target_dev}" /mnt;
        btrfs subvolume create /mnt/@;
        btrfs subvolume create /mnt/@home;
        btrfs subvolume create /mnt/@log;
        btrfs subvolume create /mnt/@pkg;
        umount /mnt;

        local m_opts="noatime,compress=zstd,ssd,discard=async";
        mount -o "${m_opts},subvol=@" "${target_dev}" /mnt;
        mount --mkdir -o "${m_opts},subvol=@home" "${target_dev}" /mnt/home;
        mount --mkdir -o "${m_opts},subvol=@log" "${target_dev}" /mnt/var/log;
        mount --mkdir -o "${m_opts},subvol=@pkg" "${target_dev}" /mnt/var/cache/pacman/pkg;
    else
        printf "[*] Creating EXT4 filesystem on %s\n" "${target_dev}";
        mkfs.ext4 -F "${target_dev}";
        mount "${target_dev}" /mnt;
    fi

    mount --mkdir "${efi_p}" /mnt/boot/efi;
}

function _run_basestrap {
    local ucode="amd-ucode";
    [[ -f /proc/cpuinfo ]] && grep -q "GenuineIntel" /proc/cpuinfo && ucode="intel-ucode";
    local pkgs=("base" "base-devel" "linux" "linux-firmware" "${ucode}" "${INIT}" "elogind-${INIT}" "efibootmgr" "dhcpcd" "dhcpcd-${INIT}" "iwd" "iwd-${INIT}" "nano");
    [[ "${FS_TYPE}" == "btrfs" ]] && pkgs+=("btrfs-progs");
    [[ "${USE_LUKS}" -eq 0 ]] && pkgs+=("cryptsetup");
    [[ "${BOOTLOADER}" == "grub" ]] && pkgs+=("grub" "os-prober") || pkgs+=("refind");
    basestrap /mnt "${pkgs[@]}";
}
function _finalize {
    local root_part uuid hooks cmdline_opts;

    if [[ "${DISK}" =~ (nvme|mmcblk|loop) ]]; then
        root_part="${DISK}p2";
    else
        root_part="${DISK}2";
    fi

    uuid=$(blkid -s UUID -o value "${root_part}") || _error_exit "Could not get UUID for ${root_part}";
    
    printf "[*] Generating fstab...\n";
    fstabgen -U /mnt >> /mnt/etc/fstab;
    
    hooks="base udev autodetect modconf block";
    [[ "${USE_LUKS}" -eq 0 ]] && hooks+=" encrypt";
    [[ "${FS_TYPE}" == "btrfs" ]] && hooks+=" btrfs";
    hooks+=" filesystems keyboard fsck";

    cmdline_opts="rw";
    [[ "${FS_TYPE}" == "btrfs" ]] && cmdline_opts+=" rootflags=subvol=@";
    [[ "${USE_LUKS}" -eq 0 ]] && cmdline_opts="cryptdevice=UUID=${uuid}:${MAPPER_NAME} root=/dev/mapper/${MAPPER_NAME} ${cmdline_opts}";

    printf "[*] Entering chroot for final configuration...\n";
    artix-chroot /mnt /bin/bash <<EOF
sed -i "s/^HOOKS=(.*/HOOKS=(${hooks})/" /etc/mkinitcpio.conf;
mkinitcpio -P;

if [[ "${BOOTLOADER}" == "grub" ]]; then
    echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub;
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"${cmdline_opts} |" /etc/default/grub;
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARTIX --recheck ${REMOVABLE_FLAG};
    grub-mkconfig -o /boot/grub/grub.cfg;
else
    refind-install;
    mkdir -p /boot/efi/EFI/refind/drivers_x64;
    cp /usr/share/refind/drivers_x64/btrfs_x64.efi /boot/efi/EFI/refind/drivers_x64/ 2>/dev/null || true;
    
    local r_root;
    [[ "${USE_LUKS}" -eq 0 ]] && r_root="/dev/mapper/${MAPPER_NAME}" || r_root="UUID=${uuid}";
    
    if [[ "${FS_TYPE}" == "btrfs" ]]; then
        printf "\"Boot Artix\" \"root=\${r_root} ${cmdline_opts} initrd=/@/boot/intel-ucode.img initrd=/@/boot/amd-ucode.img initrd=/@/boot/initramfs-linux.img\"\n" > /boot/refind_linux.conf;
    else
        printf "\"Boot Artix\" \"root=\${r_root} ${cmdline_opts} initrd=/boot/intel-ucode.img initrd=/boot/amd-ucode.img initrd=/boot/initramfs-linux.img\"\n" > /boot/refind_linux.conf;
    fi
fi

printf "root:${ROOTPASS}" | chpasswd;

case "${INIT}" in
    openrc) rc-update add dhcpcd default; rc-update add iwd default ;;
    runit)  ln -s /etc/runit/sv/dhcpcd /etc/runit/runsvdir/default/ 2>/dev/null || true; ln -s /etc/runit/sv/iwd /etc/runit/runsvdir/default/ 2>/dev/null || true ;;
    dinit)  mkdir -p /etc/dinit.d/boot.d; ln -s ../dhcpcd /etc/dinit.d/boot.d/ 2>/dev/null || true; ln -s ../iwd /etc/dinit.d/boot.d/ 2>/dev/null || true ;;
esac
EOF
}

function _setup_handoff {
    local p search_paths=( "${SCRIPT_DIR}/../" "${SCRIPT_DIR}/" );
    for p in "${search_paths[@]}"; do
        if [[ -f "${p}firstboot.sh" ]]; then
            install -Dm755 "${p}firstboot.sh" /mnt/usr/local/bin/firstboot.sh;
            install -Dm755 "${p}firstboot_trigger.sh" /mnt/etc/profile.d/firstboot.sh;
            break;
        fi
    done
}

function main {
    [[ ! -d /sys/firmware/efi ]] && _error_exit "no uefi";
    _ensure_tools;
    _choose_fs;
    _choose_init;
    _choose_bootloader;
    _setup_encryption;
    _ask_info;
    _partition_storage;
    _run_basestrap;
    _finalize;
    _setup_handoff;
    umount -R /mnt;
    printf "Done. %s system ready.\n" "${FS_TYPE^^}";
}

main;
