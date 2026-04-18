#!/bin/bash
set -euo pipefail

INIT="openrc"
[[ -d /run/runit ]] && INIT="runit"
[[ -d /run/dinit ]] && INIT="dinit"
[[ -d /run/s6 ]]    && INIT="s6"

setup_networking() {
    if ! ping -c 1 8.8.8.8 &>/dev/null; then
        case "$INIT" in
            openrc) rc-service iwd start 2>/dev/null || true ;;
            dinit)  dinitctl start iwd 2>/dev/null || true ;;
        esac
        sleep 2
        iwctl
    fi
}

create_user() {
    read -rp "Username: " un
    read -rp "Shell: 1) Bash 2) Zsh: " shc
    local ush="/bin/bash"
    [[ "$shc" == "2" ]] && { pacman -S --noconfirm zsh; ush="/bin/zsh"; }
    useradd -m -G wheel,audio,video,storage,input -s "$ush" "$un"
    passwd "$un"
    pacman -S --noconfirm sudo
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
}

setup_audio() {
    echo "1) Pipewire 2) PulseAudio 3) None"
    read -rp "Audio: " ac
    case "$ac" in
        1) pacman -S --noconfirm pipewire pipewire-pulse wireplumber pipewire-$INIT ;;
        2) pacman -S --noconfirm pulseaudio pulseaudio-$INIT ;;
    esac
}

setup_desktop() {
    echo "1) XFCE4 2) LXQt 3) LXDE 4) None"
    read -rp "DE: " dc
    local pkgs=""
    local dm=""
    local common="network-manager-applet gvfs gvfs-mtp"

    case "$dc" in
        1) pkgs="xfce4 xfce4-goodies $common"; dm="lightdm" ;;
        2) pkgs="lxqt pavucontrol-qt $common"; dm="lightdm" ;;
        3) pkgs="lxde lxappearance $common"; dm="lightdm" ;;
        *) return 0 ;;
    esac

    if [[ "$dc" =~ ^(2|3)$ ]]; then
        echo "WARNING: SDDM is RedHat-code reliant. LightDM is agnostic."
        read -rp "1) LightDM 2) SDDM: " dmc
        [[ "$dmc" == "2" ]] && dm="sddm"
    fi

    pacman -S --noconfirm $pkgs $dm $dm-$INIT
    [[ "$dm" == "lightdm" ]] && pacman -S --noconfirm lightdm-gtk-greeter

    case "$INIT" in
        openrc) rc-update add $dm default ;;
        runit)  ln -s /etc/runit/sv/$dm /etc/runit/runsvdir/default/ ;;
        dinit)  mkdir -p /etc/dinit.d/boot.d; ln -s ../$dm /etc/dinit.d/boot.d/ ;;
        s6)     s6-rc-bundle-update add default $dm ;;
    esac
}

install_drivers() {
    echo "--- Hardware Drivers ---"
    read -rp "Install detected hardware drivers (GPU/VM)? (y/N): " drv_ans
    [[ ! "$drv_ans" =~ ^([yY])$ ]] && return 0

    local pkgs=""
    if lspci | grep -qi "nvidia"; then pkgs="nvidia-dkms nvidia-utils"
    elif lspci | grep -qi "intel"; then pkgs="xf86-video-intel"
    elif lspci | grep -qi "amd"; then pkgs="xf86-video-amdgpu"; fi
    
    local virt=$(systemd-detect-virt || echo "none")
    [[ "$virt" == "oracle" ]] && pkgs="$pkgs virtualbox-guest-utils-$INIT"
    [[ -n "$pkgs" ]] && pacman -S --noconfirm $pkgs
}

enable_arch_repos() {
    read -rp "Enable Arch Repos? (y/N): " ar
    if [[ "$ar" =~ ^([yY])$ ]]; then
        pacman -S --noconfirm artix-archlinux-support
        artix-config-n-install
        pacman-key --populate archlinux
    fi
}

install_bonus_tools() {
    read -rp "Install Extra Tools (Git, Codecs, BT, UFW)? (y/N): " bt
    if [[ "$bt" =~ ^([yY])$ ]]; then
        pacman -S --noconfirm git base-devel gst-plugins-good gst-libav ufw ufw-$INIT
        
        read -rp "Enable Bluetooth? (y/N): " btc
        if [[ "$btc" =~ ^([yY])$ ]]; then
            pacman -S --noconfirm bluez bluez-$INIT
            case "$INIT" in
                openrc) rc-update add bluetooth default ;;
                runit)  ln -s /etc/runit/sv/bluetooth /etc/runit/runsvdir/default/ ;;
                dinit)  ln -s ../bluetooth /etc/dinit.d/boot.d/ ;;
            esac
        fi

        read -rp "Install Flatpak? (y/N): " fc
        [[ "$fc" =~ ^([yY])$ ]] && pacman -S --noconfirm flatpak

        read -rp "Install Zram? (y/N): " zc
        [[ "$zc" =~ ^([yY])$ ]] && { pacman -S --noconfirm zramen-$INIT || pacman -S --noconfirm zram-tools; }

        if [[ "$INIT" == "runit" ]]; then
            read -rp "Install Sashex's rsvc? (y/N): " rc
            [[ "$rc" =~ ^([yY])$ ]] && pacman -S --noconfirm rsvc
        fi
    fi
}

cleanup() {
    touch /var/lib/artix-firstboot-done
    rm -f /etc/profile.d/firstboot.sh
}

main() {
    setup_networking
    create_user
    setup_audio
    setup_desktop
    install_drivers
    enable_arch_repos
    install_bonus_tools
    cleanup
}

main
