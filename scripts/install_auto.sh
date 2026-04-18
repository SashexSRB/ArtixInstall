#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOCALE="en_US.UTF-8"
TIMEZONE="Europe/Berlin"
H_NAME="artix"

# Editable VARs
DISK=""
EFI_SIZE="1024"
EFI_PART=""
ROOT_PART=""
ROOTPASS=""
INIT=""
X_SERVER=""
DE_PKGS=""
ADD_ARCH_REPOS="no"
SWAP_CHOICE=""

# Fork options
AUDIO_PKGS=""
BT_PKGS=""
USER_SHELL="/bin/bash"
SHELL_PKGS=""
ELOGIND_PKGS=""

hr() {
    echo "--------------------------------------------------------"
}

# Live USB INIT system
detect_init() {
    if [ -f /run/runit/runsvdir/current ]; then
        INIT="runit"
    elif [ -d /run/openrc ]; then
        INIT="openrc"
    elif [ -d /run/dinit ]; then
        INIT="dinit"
    elif [ -f /run/s6/services ]; then
        INIT="s6"
    else
        echo "[ERROR] Could not detect init system."
        exit 1
    fi
    echo "[*] Detected init system: $INIT"
}

# Is UEFI?
check_efi() {
    if [[ ! -d /sys/firmware/efi ]]; then
        echo "[ERROR] EFI mode required (UEFI). Please reboot in UEFI mode."
        exit 1
    fi
}

# Pacman setup + Util setup
ensure_tools() {
    echo "[*] Optimizing pacman and enabling Galaxy repo..."
    
    # Parallel downloads
    sudo sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf
    
    # Galaxy repos
    if ! grep -q "^\[galaxy\]" /etc/pacman.conf; then
        echo -e "\n[galaxy]\nInclude = /etc/pacman.d/mirrorlist-galaxy" | sudo tee -a /etc/pacman.conf
    fi

    # Tools / Utils
    local pkgs=("gptfdisk" "dosfstools" "util-linux" "artix-install-scripts" "parted")
    
    sudo pacman -Sy --noconfirm
    for pkg in "${pkgs[@]}"; do
        if ! pacman -Qs "$pkg" > /dev/null; then
            sudo pacman -S --noconfirm "$pkg"
        fi
    done
}

# X server + DE + Extras
ask_options() {
    hr
    read -rsp "Enter root password: " ROOTPASS; echo
    
    hr
    echo "Choose X Server:"
    echo "1) Xorg (Standard)"
    echo "2) Xlibre (Modern fork)"
    read -rp "Selection [1-2]: " xc
    if [[ "$xc" == "2" ]]; then
        X_SERVER="xlibre-xserver xlibre-xserver-common xlibre-input-libinput"
    else
        X_SERVER="xorg-server xorg-xinit xf86-input-libinput"
    fi

    hr
    echo "Choose Desktop Environment:"
    echo "1) XFCE"
    echo "2) LXQt"
    echo "3) LXDE"
    echo "4) None"
    read -rp "Selection [1-4]: " dc
    case "$dc" in
        1) DE_PKGS="xfce4 xfce4-goodies lightdm lightdm-$INIT lightdm-gtk-greeter" ;;
        2) DE_PKGS="lxqt sddm sddm-$INIT" ;;
        3) DE_PKGS="lxde sddm sddm-$INIT" ;;
        *) DE_PKGS="" ;;
    esac

    hr
    echo "--- Fork Extras ---"
    echo "Choose Audio System:"
    echo "1) Pipewire (Modern/Recommended)"
    echo "2) PulseAudio (Classic)"
    echo "3) None"
    read -rp "Selection [1-3]: " ac
    case "$ac" in
        1) AUDIO_PKGS="pipewire pipewire-pulse wireplumber pipewire-$INIT" ;;
        2) AUDIO_PKGS="pulseaudio pulseaudio-$INIT" ;;
    esac

    hr
    read -rp "Install Bluetooth Support? (y/N): " bc
    if [[ "$bc" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        BT_PKGS="bluez bluez-$INIT"
    fi

    hr
    echo "Choose Default Shell:"
    echo "1) Bash (Standard)"
    echo "2) Zsh (Advanced)"
    read -rp "Selection [1-2]: " sc
    if [[ "$sc" == "2" ]]; then
        USER_SHELL="/bin/zsh"
        SHELL_PKGS="zsh zsh-completions"
    else
        USER_SHELL="/bin/bash"
    fi

    hr
    read -rp "Enable Elogind? (Highly recommended for DEs) (Y/n): " ec
    if [[ "$ec" =~ ^([nN][oO]|[nN])$ ]]; then
        ELOGIND_PKGS=""
    else
        ELOGIND_PKGS="elogind-$INIT"
    fi

    hr
    echo "Choose Swap Type:"
    echo "1) Swap File (RAM x 2)"
    echo "2) Swap Partition (RAM x 2)"
    echo "3) None"
    read -rp "Selection [1-3]: " sc
    SWAP_CHOICE=$sc

    hr
    read -rp "Enable Arch Linux Repositories? (y/N): " ar
    if [[ "$ar" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        ADD_ARCH_REPOS="yes"
    fi
}

# Disk selection
select_disk() {
    hr
    echo "Available Disks:"
    lsblk -dpno NAME,SIZE,MODEL | grep -v loop
    read -rp "Enter target disk (e.g. /dev/sda): " DISK
    
    if [[ ! -b "$DISK" ]]; then
        echo "[ERROR] Invalid device: $DISK"
        exit 1
    fi
}

# EFI + Root
prepare_disk() {
    hr
    echo "[*] Wiping and partitioning $DISK..."
    umount -R /mnt 2>/dev/null || true
    wipefs -a "$DISK"
    sgdisk --zap-all "$DISK"
    
    # 1: EFI (1GB)
    sgdisk -n 1:0:+${EFI_SIZE}M -t 1:ef00 "$DISK"
    
    local ram_m=$(free -m | awk '/^Mem:/{print $2}')
    local s_size=$((ram_m * 2))

    # Define partition names
    if [[ "$DISK" =~ "nvme" ]]; then
        EFI_PART="${DISK}p1"
        if [[ "$SWAP_CHOICE" == "2" ]]; then
            ROOT_PART="${DISK}p3"
            SWAP_PART="${DISK}p2"
        else
            ROOT_PART="${DISK}p2"
        fi
    else
        EFI_PART="${DISK}1"
        if [[ "$SWAP_CHOICE" == "2" ]]; then
            ROOT_PART="${DISK}3"
            SWAP_PART="${DISK}2"
        else
            ROOT_PART="${DISK}2"
        fi
    fi

    if [[ "$SWAP_CHOICE" == "2" ]]; then
        echo "[*] Creating Swap Partition..."
        sgdisk -n 2:0:+${s_size}M -t 2:8200 "$DISK"
        sgdisk -n 3:0:0           -t 3:8300 "$DISK"
        mkswap "$SWAP_PART"
        swapon "$SWAP_PART"
    else
        echo "[*] Creating Root Partition..."
        sgdisk -n 2:0:0 -t 2:8300 "$DISK"
    fi

    echo "[*] Formatting partitions..."
    mkfs.fat -F32 "$EFI_PART"
    mkfs.ext4 -F "$ROOT_PART"
    
    echo "[*] Mounting partitions..."
    mount "$ROOT_PART" /mnt
    mount --mkdir "$EFI_PART" /mnt/boot/efi
}

# Base installation
install_base() {
    hr
    local ucode=""
    if grep -q "GenuineIntel" /proc/cpuinfo; then ucode="intel-ucode"; else ucode="amd-ucode"; fi
    
    local gpu_driver=""
    if lspci | grep -qi "vga\|display"; then
        if lspci | grep -qi "nvidia"; then
            gpu_driver="nvidia-dkms nvidia-utils"
        elif lspci | grep -qi "intel"; then
            [[ "$X_SERVER" == *"xlibre"* ]] && gpu_driver="xlibre-video-intel" || gpu_driver="xf86-video-intel"
        elif lspci | grep -qi "amd\|ati"; then
            [[ "$X_SERVER" == *"xlibre"* ]] && gpu_driver="xlibre-video-amdgpu" || gpu_driver="xf86-video-amdgpu"
        fi
    fi

    local vm_tools=""
    local virt_type=$(systemd-detect-virt || echo "none")
    if [[ "$virt_type" == "oracle" ]]; then 
        vm_tools="virtualbox-guest-utils-$INIT"
    elif [[ "$virt_type" == "vmware" ]]; then
        vm_tools="open-vm-tools-$INIT"
    fi

    local extra_pkgs=""
    if [[ "$ADD_ARCH_REPOS" == "yes" ]]; then extra_pkgs="artix-archlinux-support"; fi

    echo "[*] Running basestrap with all selected components..."
    basestrap /mnt base base-devel linux linux-firmware $ucode \
        $INIT $ELOGIND_PKGS grub efibootmgr os-prober \
        dhcpcd dhcpcd-$INIT iwd iwd-$INIT nano \
        $X_SERVER $gpu_driver $DE_PKGS $AUDIO_PKGS $BT_PKGS $SHELL_PKGS $vm_tools $extra_pkgs
}

# Chroot config
configure_system() {
    hr
    echo "[*] Generating fstab..."
    fstabgen -U /mnt >> /mnt/etc/fstab
    
    local ram_m=$(free -m | awk '/^Mem:/{print $2}')
    local s_size=$((ram_m * 2))
    
    local dm_service=""
    [[ "$DE_PKGS" =~ "lightdm" ]] && dm_service="lightdm"
    [[ "$DE_PKGS" =~ "sddm" ]] && dm_service="sddm"

    echo "[*] Configuring system in chroot..."
    artix-chroot /mnt /bin/bash <<EOF
# Time & Localization
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "$LOCALE UTF-8" >> /etc/locale.gen && locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "$H_NAME" > /etc/hostname

# Password
echo "root:$ROOTPASS" | chpasswd

# Bootloader
echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARTIX --recheck --removable
grub-mkconfig -o /boot/grub/grub.cfg

# Swap File
if [[ "$SWAP_CHOICE" == "1" ]]; then
    echo "[*] Creating ${s_size}MB swap file..."
    dd if=/dev/zero of=/swapfile bs=1M count=$s_size status=progress
    chmod 600 /swapfile && mkswap /swapfile
    echo "/swapfile none swap defaults 0 0" >> /etc/fstab
fi

# DYNAMIC SERVICES
echo "[*] Enabling services for $INIT..."
for svc in dhcpcd iwd bluetooth $dm_service; do
    [ -z "\$svc" ] && continue
    if [[ "\$svc" == "bluetooth" && -z "$BT_PKGS" ]]; then continue; fi

    case "$INIT" in
        openrc) rc-update add \$svc default ;;
        runit)  ln -s /etc/runit/sv/\$svc /etc/runit/runsvdir/default/ ;;
        dinit)  mkdir -p /etc/dinit.d/boot.d && ln -s ../\$svc /etc/dinit.d/boot.d/ ;;
        s6)     s6-rc-bundle-update add default \$svc ;;
    esac
done

# Arch Repos
if [[ "$ADD_ARCH_REPOS" == "yes" ]]; then
    artix-config-n-install
    pacman-key --populate archlinux
fi
EOF

    # Save shell choice 
    echo "$USER_SHELL" > /mnt/tmp/shell_choice

    # Post install scripts
    hr
    if [ -f "$SCRIPT_DIR/../firstboot.sh" ]; then
        echo "[*] Copying post-install scripts from parent directory..."
        install -Dm755 "$SCRIPT_DIR/../firstboot.sh" /mnt/usr/local/bin/firstboot.sh
        install -Dm755 "$SCRIPT_DIR/../firstboot_trigger.sh" /mnt/etc/profile.d/firstboot.sh
    elif [ -f "$SCRIPT_DIR/firstboot.sh" ]; then
        echo "[*] Copying post-install scripts from current directory..."
        install -Dm755 "$SCRIPT_DIR/firstboot.sh" /mnt/usr/local/bin/firstboot.sh
        install -Dm755 "$SCRIPT_DIR/firstboot_trigger.sh" /mnt/etc/profile.d/firstboot.sh
    else
        echo "[WARNING] Post-install scripts not found! Skipping..."
    fi
}

main() {
    clear
    hr
    echo "============================================="
    echo "      ARTIX LINUX INSTALLER (AUTO MODE)      "
    echo "============================================="
    hr
    
    check_efi
    detect_init
    ensure_tools
    ask_options
    select_disk
    prepare_disk
    install_base
    configure_system
    
    umount -R /mnt
    hr
    echo "[✓] AUTO INSTALLATION COMPLETE! You can reboot."
}

main
