#!/usr/bin/env bash
set -euo pipefail;

ROOTPASS="";
INIT="";
BOOTLOADER="grub";
REMOVABLE_FLAG="";
MAPPER_NAME="cryptroot";
IS_BTRFS=1;

SELF_PATH="${BASH_SOURCE}";
[[ "${SELF_PATH}" != /* ]] && SELF_PATH="${PWD}/${SELF_PATH}";
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

function _verify_mounts {
    findmnt /mnt >/dev/null || _error_exit "/mnt is not mounted.";
    findmnt /mnt/boot/efi >/dev/null || _error_exit "/mnt/boot/efi is not mounted.";
}

function _choose_init {
    printf "1) openrc  2) runit  3) dinit  4) s6\n";
    printf "Init: "; read -r ic;
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
    printf "Bootloader: "; read -r bc;
    [[ "${bc}" == "2" ]] && BOOTLOADER="refind" || BOOTLOADER="grub";
}

function _ask_info {
    printf "Root password: "; read -rs ROOTPASS; echo;
    _ask "Installing to a removable/external drive?" "n" && REMOVABLE_FLAG="--removable";
}

function _detect_storage_stack {
    local root_fs;
    read -r root_fs < <(findmnt -no FSTYPE /mnt);
    [[ "${root_fs}" == "btrfs" ]] && IS_BTRFS=0;
}

function _run_basestrap {
    local ucode="amd-ucode";
    [[ -f /proc/cpuinfo ]] && grep -q "GenuineIntel" /proc/cpuinfo && ucode="intel-ucode";
    local pkgs=("base" "base-devel" "linux" "linux-firmware" "${ucode}" "${INIT}" "elogind-${INIT}" "efibootmgr" "dhcpcd" "dhcpcd-${INIT}" "iwd" "iwd-${INIT}" "nano");
    
    [[ "${IS_BTRFS}" -eq 0 ]] && pkgs+=( "btrfs-progs" );
    
    local source_dev;
    read -r source_dev < <(findmnt -no SOURCE /mnt);
    [[ "${source_dev}" == /dev/mapper/* ]] && pkgs+=( "cryptsetup" );
    
    [[ "${BOOTLOADER}" == "grub" ]] && pkgs+=( "grub" "os-prober" ) || pkgs+=( "refind" );

    basestrap /mnt "${pkgs[@]}";
}

function _finalize {
    local root_dev real_dev uuid="" subvol_arg="" current_mapper="";
    read -r root_dev < <(findmnt -no SOURCE /mnt);

    if [[ "${IS_BTRFS}" -eq 0 ]]; then
        local opts;
        read -r opts < <(findmnt -no OPTIONS /mnt);
        if [[ "${opts}" == *subvol=* ]]; then
            local temp="${opts#*subvol=}";
            subvol_arg="rootflags=subvol=${temp%%,*}";
        fi
    fi

    if [[ "${root_dev}" == /dev/mapper/* ]]; then
        current_mapper="${root_dev##*/}";
        read -r real_dev < <(cryptsetup status "${current_mapper}" | awk '/device:/ {print $2}');
        read -r uuid < <(blkid -s UUID -o value "${real_dev}");
    fi

    fstabgen -U /mnt >> /mnt/etc/fstab;
    
    artix-chroot /mnt /bin/bash <<EOF
hooks="base udev autodetect modconf block";
[[ -n "${uuid}" ]] && hooks+=" encrypt";
[[ "${IS_BTRFS}" -eq 0 ]] && hooks+=" btrfs";
hooks+=" filesystems keyboard fsck";

sed -i "s/^HOOKS=(.*/HOOKS=(\${hooks})/" /etc/mkinitcpio.conf;
mkinitcpio -P;

if [[ "${BOOTLOADER}" == "grub" ]]; then
    echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub;
    cmd="rw ";
    [[ -n "${uuid}" ]] && cmd+="cryptdevice=UUID=${uuid}:${current_mapper:-cryptroot} root=${root_dev} ";
    [[ -n "${subvol_arg}" ]] && cmd+="${subvol_arg} ";
    
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\${cmd}|" /etc/default/grub;
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARTIX --recheck ${REMOVABLE_FLAG};
    grub-mkconfig -o /boot/grub/grub.cfg;
else
    refind-install;
    params="rw ";
    [[ -n "${uuid}" ]] && params+="cryptdevice=UUID=${uuid}:${current_mapper:-cryptroot} root=${root_dev} ";
    [[ -n "${subvol_arg}" ]] && params+="${subvol_arg} ";
    printf "\"Boot Artix\" \"%s initrd=/boot/intel-ucode.img initrd=/boot/amd-ucode.img initrd=/boot/initramfs-linux.img\"\n" "\${params}" > /boot/refind_linux.conf;
fi

printf "root:%s" "${ROOTPASS}" | chpasswd;
case "${INIT}" in
    openrc) rc-update add dhcpcd default; rc-update add iwd default ;;
    runit)  ln -s /etc/runit/sv/dhcpcd /etc/runit/runsvdir/default/; ln -s /etc/runit/sv/iwd /etc/runit/runsvdir/default/ ;;
    dinit)  mkdir -p /etc/dinit.d/boot.d; ln -s ../dhcpcd /etc/dinit.d/boot.d/; ln -s ../iwd /etc/dinit.d/boot.d/ ;;
esac
EOF
}

function _setup_handoff {
    local p search_paths=( "${SCRIPT_DIR}/../" "${SCRIPT_DIR}/" );
    for p in "${search_paths[@]}"; do
        if [[ -f "${p}firstboot.sh" ]]; then
            install -Dm755 "${p}firstboot.sh" /mnt/usr/local/bin/firstboot.sh;
            install -Dm755 "${p}firstboot_trigger.sh" /mnt/etc/profile.d/firstboot.sh;
            return 0;
        fi
    done
}

function main {
    [[ ! -d /sys/firmware/efi ]] && _error_exit "no uefi";
    _verify_mounts;
    _choose_init;
    _choose_bootloader;
    _ask_info;
    _detect_storage_stack;
    _run_basestrap;
    _finalize;
    _setup_handoff;
    umount -R /mnt;
    
    local fs_msg="EXT4"; [[ "${IS_BTRFS}" -eq 0 ]] && fs_msg="BTRFS";
    printf "Manual install complete. %s stack configured.\n" "${fs_msg}";
}

main;
