#!/bin/bash

INIT="openrc"
[[ -d /run/runit ]] && INIT="runit"
[[ -d /run/dinit ]] && INIT="dinit"
[[ -d /run/s6 ]]    && INIT="s6"

setup_networking() {
    echo "--- Networking ---"
    if ping -c 1 8.8.8.8 &>/dev/null; then
        echo "[✓] Internet connection is active."
        return 0
    fi

    case "$INIT" in
        openrc) rc-service iwd start 2>/dev/null || true ;;
        dinit)  dinitctl start iwd 2>/dev/null || true ;;
    esac
    sleep 2
    iwctl
}

create_user() {
    echo "--- User Setup ---"
    read -rp "Username (leave empty to skip): " un
    [[ -z "$un" ]] && return 0

    if id "$un" &>/dev/null; then
        echo "[!] User '$un' already exists."
        read -rp "Reset password for this user? (y/N): " res_pass
        [[ "$res_pass" =~ ^([yY])$ ]] && passwd "$un"
    else
        read -rp "Shell: 1) Bash 2) Zsh: " shc
        local ush="/bin/bash"
        [[ "$shc" == "2" ]] && { pacman -S --noconfirm zsh; ush="/bin/zsh"; }
        useradd -m -G wheel,audio,video,storage,input -s "$ush" "$un"
        passwd "$un"
    fi

    pacman -S --noconfirm sudo
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers 2>/dev/null || \
    sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers
}

setup_audio() {
    echo "--- Audio Setup ---"
    if pacman -Qs pipewire >/dev/null || pacman -Qs pulseaudio >/dev/null; then
        echo "[✓] Audio packages already detected."
        read -rp "Reinstall/Change audio? (y/N): " ra
        [[ ! "$ra" =~ ^([yY])$ ]] && return 0
    fi

    echo "1) Pipewire 2) PulseAudio 3) None"
    read -rp "Audio: " ac
    case "$ac" in
        1) pacman -S --noconfirm pipewire pipewire-pulse wireplumber pipewire-$INIT ;;
        2) pacman -S --noconfirm pulseaudio pulseaudio-$INIT ;;
    esac
}

setup_desktop() {
    echo "--- Desktop Environment ---"
    if pacman -Qs lightdm >/dev/null || pacman -Qs sddm >/dev/null; then
        echo "[✓] A Display Manager appears to be installed."
        read -rp "Install/Change Desktop anyway? (y/N): " rd
        [[ ! "$rd" =~ ^([yY])$ ]] && return 0
    fi

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
        openrc) rc-update add $dm default 2>/dev/null || true ;;
        runit)  ln -s /etc/runit/sv/$dm /etc/runit/runsvdir/default/ 2>/dev/null || true ;;
        dinit)  mkdir -p /etc/dinit.d/boot.d; ln -s ../$dm /etc/dinit.d/boot.d/ 2>/dev/null || true ;;
        s6)     s6-rc-bundle-update add default $dm 2>/dev/null || true ;;
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
    echo "--- Arch Linux Repositories ---"
    if grep -q "^\[extra\]" /etc/pacman.conf; then
        echo "[✓] Arch repositories are already configured."
        return 0
    fi

    read -rp "Enable Arch Repos? (y/N): " ar
    if [[ "$ar" =~ ^([yY])$ ]]; then
        pacman -Sy --noconfirm artix-archlinux-support
        hash -r
        if command -v artix-config-n-install &>/dev/null; then
            artix-config-n-install
            pacman-key --populate archlinux
            pacman -Sy
        else
            /usr/bin/artix-config-n-install && pacman-key --populate archlinux && pacman -Sy
        fi
    fi
}

install_bonus_tools() {
    echo "--- Bonus Tools ---"
    read -rp "Install Extras (Git, Codecs, BT, UFW, rsvc)? (y/N): " bt
    [[ ! "$bt" =~ ^([yY])$ ]] && return 0

    pacman -S --noconfirm git base-devel gst-plugins-good gst-libav ufw ufw-$INIT
    
    read -rp "Enable Bluetooth? (y/N): " btc
    if [[ "$btc" =~ ^([yY])$ ]]; then
        pacman -S --noconfirm bluez bluez-$INIT
        case "$INIT" in
            openrc) rc-update add bluetooth default 2>/dev/null || true ;;
            runit)  ln -s /etc/runit/sv/bluetooth /etc/runit/runsvdir/default/ 2>/dev/null || true ;;
            dinit)  ln -s ../bluetooth /etc/dinit.d/boot.d/ 2>/dev/null || true ;;
        esac
    fi

    read -rp "Install Flatpak? (y/N): " fc
    [[ "$fc" =~ ^([yY])$ ]] && pacman -S --noconfirm flatpak

    read -rp "Install Zram? (y/N): " zc
    [[ "$zc" =~ ^([yY])$ ]] && { pacman -S --noconfirm zramen-$INIT 2>/dev/null || pacman -S --noconfirm zram-tools 2>/dev/null || true; }

    if [[ "$INIT" == "runit" ]]; then
        read -rp "Install Sashex's rsvc? (y/N): " rc
        [[ "$rc" =~ ^([yY])$ ]] && pacman -S --noconfirm rsvc
    fi
}

main() {
    echo "======================================="
    echo "   ARTIX POST-INSTALL SCRIPT           "
    echo "======================================="

    setup_networking
    create_user
    setup_audio
    setup_desktop
    install_drivers
    enable_arch_repos
    install_bonus_tools

    echo "--- Finalize ---"
    read -rp "All done? Remove wizard from startup? (y/N): " final
    if [[ "$final" =~ ^([yY])$ ]]; then
        touch /var/lib/artix-firstboot-done
        rm -f /etc/profile.d/firstboot.sh
        echo "[✓] Cleanup complete. Enjoy your system!"
    else
        echo "[!] Wizard kept. You can run it again by logging in as root."
    fi
}

main
