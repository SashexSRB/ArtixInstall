#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOCALE="en_US.UTF-8"
TIMEZONE="Europe/Berlin"
H_NAME="artix"

# Editable VARs
INIT=""
X_SERVER=""
DE_PKGS=""
ADD_ARCH_REPOS="no"
ROOTPASS=""

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

# Detect mounts
detect_mounted() {
    hr
    echo "[*] Checking mount points..."
    if ! findmnt /mnt >/dev/null; then
        echo "[ERROR] Nothing mounted on /mnt. Please mount your Root partition."
        exit 1
    fi
    if ! findmnt /mnt/boot/efi >/dev/null; then
        echo "[ERROR] Nothing mounted on /mnt/boot/efi. Please mount your EFI partition."
        exit 1
    fi
    echo "[✓] Partitions correctly mounted."
}

# Pacman setup + Util setup
ensure_tools() {
    hr
    echo "[*] Optimizing pacman and enabling Galaxy repo..."
    
    # Parallel downloads
    sudo sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf
    
    # Galaxy repos
    if ! grep -q "^\[galaxy\]" /etc/pacman.conf; then
        echo -e "\n[galaxy]\nInclude = /etc/pacman.d/mirrorlist-galaxy" | sudo tee -a /etc/pacman.conf
    fi

    sudo pacman -Sy --noconfirm artix-install-scripts
}

# X server + DE + Extras
ask_options() {
    hr
    read -rsp "Enter root password: " ROOTPASS; echo
    
    hr
    echo "Choose X Server:"
    echo "1) Xorg (Standard)"
    echo "2) Xlibre (Modern fork)"
    read -rp "Selection [1-2]: " x_choice
    if [[ "$x_choice" == "2" ]]; then
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
    read -rp "Selection [1-4]: " de_choice
    case "$de_choice" in
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
    echo "WARNING: Arch Repos can be unstable on Artix!"
    read -rp "Enable Arch Linux Repositories? (y/N): " arch_ans
    if [[ "$arch_ans" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        ADD_ARCH_REPOS="yes"
    fi
}

# Main
main() {
    # Is UEFI?
    if [[ ! -d /sys/firmware/efi ]]; then echo "[ERROR] UEFI required."; exit 1; fi
    
    detect_init
    detect_mounted
    ensure_tools
    ask_options

    hr
    # AMD or Intel? (Microcode)
    local ucode=""
    if grep -q "GenuineIntel" /proc/cpuinfo; then ucode="intel-ucode"; else ucode="amd-ucode"; fi
    
    # Graphics drivers
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

    # Is a VM?
    local vm_tools=""
    local virt_type=$(systemd-detect-virt || echo "none")
    if [[ "$virt_type" == "oracle" ]]; then 
        vm_tools="virtualbox-guest-utils-$INIT"
    elif [[ "$virt_type" == "vmware" ]]; then
        vm_tools="open-vm-tools-$INIT"
    fi

    local extra_pkgs=""
    if [[ "$ADD_ARCH_REPOS" == "yes" ]]; then extra_pkgs="artix-archlinux-support"; fi

    echo "[*] Basestrap in progress with selected components..."
    basestrap /mnt base base-devel linux linux-firmware $ucode \
        $INIT $ELOGIND_PKGS grub efibootmgr os-prober \
        dhcpcd dhcpcd-$INIT iwd iwd-$INIT nano \
        $X_SERVER $gpu_driver $DE_PKGS $AUDIO_PKGS $BT_PKGS $SHELL_PKGS $vm_tools $extra_pkgs
    
    echo "[*] Generating fstab..."
    fstabgen -U /mnt >> /mnt/etc/fstab

    # Swap math
    local total_ram=$(free -m | awk '/^Mem:/{print $2}')
    local swap_size=$((total_ram * 2))

    # DM?
    local dm_service=""
    [[ "$DE_PKGS" =~ "lightdm" ]] && dm_service="lightdm"
    [[ "$DE_PKGS" =~ "sddm" ]] && dm_service="sddm"

    echo "[*] Entering chroot for configuration..."
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

# Swap (RAMx2)
echo "[*] Creating ${swap_size}MB swap file..."
dd if=/dev/zero of=/swapfile bs=1M count=$swap_size status=progress
chmod 600 /swapfile && mkswap /swapfile
echo "/swapfile none swap defaults 0 0" >> /etc/fstab

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

    umount -R /mnt
    echo "[✓] MANUAL INSTALLATION COMPLETE! You can reboot."
}

main
