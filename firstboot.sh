#!/bin/bash

set -o pipefail

INIT="openrc"
[[ -d /run/runit ]] && INIT="runit"
[[ -d /run/dinit ]] && INIT="dinit"
[[ -d /run/s6 ]]    && INIT="s6"

setup_networking() {
    echo "--- Networking ---"
    if ping -c 1 8.8.8.8 &>/dev/null; then
        echo "[✓] Online."
        return 0
    fi
    case "$INIT" in
        openrc) rc-service iwd start 2>/dev/null || true ;;
        dinit)  dinitctl start iwd 2>/dev/null || true ;;
    esac
    sleep 2
    iwctl
}

enable_arch_repos() {
    echo "--- Arch Repositories ---"
    if grep -q "^\[extra\]" /etc/pacman.conf; then
        echo "[✓] Already configured."
        return 0
    fi

    read -rp "Enable Arch Repos? (Required for LXQt/LXDE/Drivers) (y/N): " ar
    if [[ "$ar" =~ ^([yY])$ ]]; then
        pacman -Sy --noconfirm artix-archlinux-support
        hash -r
        if command -v artix-config-n-install &>/dev/null; then
            artix-config-n-install
        else
            /usr/bin/artix-config-n-install
        fi
        pacman-key --populate archlinux
        pacman -Sy
    else
        echo "[!] Skipping Arch repos. Some DEs or drivers might fail to install."
    fi
}
create_user() {
    echo "--- User Setup ---"
    read -rp "Username: " un
    [[ -z "$un" ]] && return 0
    if id "$un" &>/dev/null; then
        echo "[!] User '$un' exists."
        read -rp "Reset password? (y/N): " res_pass
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
        read -rp "Audio detected. Reinstall? (y/N): " ra
        [[ ! "$ra" =~ ^([yY])$ ]] && return 0
    fi
    echo "1) Pipewire 2) PulseAudio 3) None"
    read -rp "Audio: " ac
    case "$ac" in
        1) 
            pacman -S --noconfirm pipewire pipewire-pulse wireplumber
            pacman -S --noconfirm pipewire-$INIT 2>/dev/null || true 
            ;;
        2) 
            pacman -S --noconfirm pulseaudio pulseaudio-alsa
            pacman -S --noconfirm pulseaudio-$INIT 2>/dev/null || true 
            ;;
    esac
}

setup_desktop() {
    echo "--- Desktop Environment ---"
    if pacman -Qs lightdm >/dev/null || pacman -Qs sddm >/dev/null; then
        read -rp "GUI detected. Reinstall? (y/N): " rd
        [[ ! "$rd" =~ ^([yY])$ ]] && return 0
    fi
    echo "1) XFCE4 2) LXQt 3) LXDE 4) None"
    echo "Note: Arch repositories will be used for LXQt/LXDE dependencies."
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
    read -rp "Install detected hardware drivers? (y/N): " drv_ans
    [[ ! "$drv_ans" =~ ^([yY])$ ]] && return 0

    echo "1) Standard X.Org (Proprietary) 2) xLibre (Open-source)"
    read -rp "Driver preference: " drv_pref
    
    local pkgs=()
    local gpu_info=$(lspci)

    if grep -iq "oracle" /sys/class/dmi/id/sys_vendor 2>/dev/null || grep -iq "virtualbox" /proc/cpuinfo; then
        echo "[i] VirtualBox detected."
        pkgs+=("virtualbox-guest-utils-$INIT" "xf86-video-vmware")
    fi

    if echo "$gpu_info" | grep -qi "nvidia"; then
        if [[ "$drv_pref" == "2" ]]; then
            pkgs+=("xlibre-video-nouveau")
        else
            pkgs+=("nvidia-dkms" "nvidia-utils")
        fi
    fi

    if echo "$gpu_info" | grep -qi "intel"; then
        if [[ "$drv_pref" == "2" ]]; then
            pkgs+=("xlibre-video-intel")
        else
            pkgs+=("xf86-video-intel" "intel-media-driver")
        fi
    fi

    if echo "$gpu_info" | grep -qi "amd"; then
        if [[ "$drv_pref" == "2" ]]; then
            pkgs+=("xlibre-video-amdgpu" "vulkan-radeon")
        else
            pkgs+=("xf86-video-amdgpu" "vulkan-radeon")
        fi
    fi

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        pacman -S --noconfirm "${pkgs[@]}"
    fi
}

install_bonus_tools() {
    echo "--- Bonus Tools ---"
    read -rp "Enter Extras Menu? (y/N): " bt_menu
    [[ ! "$bt_menu" =~ ^([yY])$ ]] && return 0

    read -rp "Install Git & Base-Devel? (y/N): " i_git
    [[ "$i_git" =~ ^([yY])$ ]] && pacman -S --noconfirm git base-devel

    read -rp "Install Codecs? (y/N): " i_cod
    [[ "$i_cod" =~ ^([yY])$ ]] && pacman -S --noconfirm gst-plugins-good gst-libav

    read -rp "Install UFW Firewall? (y/N): " i_ufw
    if [[ "$i_ufw" =~ ^([yY])$ ]]; then
        pacman -S --noconfirm ufw ufw-$INIT
        case "$INIT" in
            openrc) rc-update add ufw default 2>/dev/null || true ;;
            runit)  ln -s /etc/runit/sv/ufw /etc/runit/runsvdir/default/ 2>/dev/null || true ;;
            dinit)  ln -s ../ufw /etc/dinit.d/boot.d/ 2>/dev/null || true ;;
        esac
    fi

    read -rp "Install Bluetooth? (y/N): " i_bt
    if [[ "$i_bt" =~ ^([yY])$ ]]; then
        pacman -S --noconfirm bluez bluez-$INIT
        case "$INIT" in
            openrc) rc-update add bluetooth default 2>/dev/null || true ;;
            runit)  ln -s /etc/runit/sv/bluetooth /etc/runit/runsvdir/default/ 2>/dev/null || true ;;
            dinit)  ln -s ../bluetooth /etc/dinit.d/boot.d/ 2>/dev/null || true ;;
        esac
    fi

    read -rp "Install Flatpak? (y/N): " i_fp
    [[ "$i_fp" =~ ^([yY])$ ]] && pacman -S --noconfirm flatpak

    read -rp "Install Zram? (y/N): " i_zr
    [[ "$i_zr" =~ ^([yY])$ ]] && { pacman -S --noconfirm zramen-$INIT 2>/dev/null || pacman -S --noconfirm zram-tools 2>/dev/null || true; }
    
    if [[ "$INIT" == "runit" ]]; then
        read -rp "Install SashexSRB's rsvc? (WARNING: Pulls git & base-devel!) (https://github.com/SashexSRB/rsvc) (y/N): " i_rv
        if [[ "$i_rv" =~ ^([yY])$ ]]; then
            echo "--- Building rsvc ---"
            pacman -S --noconfirm git base-devel && \
            git clone https://github.com/SashexSRB/rsvc /tmp/rsvc && {
                cd /tmp/rsvc || return 1
                make
                make install
                cd - >/dev/null || return 1
                rm -rf /tmp/rsvc
                echo "[✓] SashexSRB's rsvc installed."
            } || echo "[!] Failed to build rsvc."
        fi
    fi

    read -rp "Install fastfetch? (y/N): " i_ff
    [[ "$i_ff" =~ ^([yY])$ ]] && pacman -S --noconfirm fastfetch
}

main() {
    echo "======================================="
    echo "   ARTIX POST-INSTALL SCRIPT           "
    echo "======================================="
    setup_networking
    enable_arch_repos
    create_user
    setup_audio
    setup_desktop
    install_drivers
    install_bonus_tools
    echo "--- Finalize ---"
    read -rp "All done. Remove wizard from startup? (y/N): " final
    if [[ "$final" =~ ^([yY])$ ]]; then
        touch /var/lib/artix-firstboot-done
        rm -f /etc/profile.d/firstboot.sh
        echo "[✓] Cleanup complete. Enjoy your system!"
        echo "To apply everything, you should reboot."
    else
        echo "[!] Wizard kept. You can run it again by logging in as root."
        echo "To apply everything, you should reboot."
    fi
}

main
