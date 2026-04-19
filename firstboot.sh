#!/bin/bash

INIT="openrc"
[[ -d /run/runit ]] && INIT="runit"
[[ -d /run/dinit ]] && INIT="dinit"
[[ -d /run/s6 ]]    && INIT="s6"

setup_networking() {
    echo "--- Networking ---"
    if ping -c 1 8.8.8.8 &>/dev/null; then
        echo "[✓] Online."
    else
        case "$INIT" in
            openrc) rc-service iwd start 2>/dev/null || true ;;
            dinit)  dinitctl start iwd 2>/dev/null || true ;;
        esac
        sleep 2
        iwctl
    fi
}

enable_arch_repos() {
    echo "--- Arch Repositories ---"
    if grep -q "^\[extra\]" /etc/pacman.conf; then
        echo "[✓] Already configured."
    else
        read -rp "Enable Arch Repos? (y/N): " ar
        if [[ "$ar" =~ ^([yY])$ ]]; then
            pacman -Sy --noconfirm artix-archlinux-support
            hash -r
            if [[ -f /usr/bin/artix-config-n-install ]]; then
                /usr/bin/artix-config-n-install && pacman-key --populate archlinux && pacman -Sy
            else
                /usr/bin/artix-config-n-install 2>/dev/null && pacman-key --populate archlinux && pacman -Sy
            fi
        else
            echo "[!] Skipping Arch repos."
        fi
    fi
}

create_user() {
    echo "--- User Setup ---"
    read -rp "Username: " un
    if [[ -n "$un" ]]; then
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
    fi
}

setup_audio() {
    echo "--- Audio Setup ---"
    local needs_audio=true
    if pacman -Qs pipewire >/dev/null || pacman -Qs pulseaudio >/dev/null; then
        read -rp "Audio detected. Reinstall? (y/N): " ra
        [[ ! "$ra" =~ ^([yY])$ ]] && needs_audio=false
    fi
    if [[ "$needs_audio" == "true" ]]; then
        echo "1) Pipewire 2) PulseAudio 3) None"
        read -rp "Audio: " ac
        case "$ac" in
            1) pacman -S --noconfirm pipewire pipewire-pulse wireplumber && pacman -S --noconfirm pipewire-$INIT 2>/dev/null || true ;;
            2) pacman -S --noconfirm pulseaudio pulseaudio-alsa && pacman -S --noconfirm pulseaudio-$INIT 2>/dev/null || true ;;
        esac
    fi
}

setup_desktop() {
    echo "--- Desktop Environment ---"
    echo "Warning: LXQt and LXDE require Arch repositories to be enabled."
    local needs_de=true
    if pacman -Qs lightdm >/dev/null || pacman -Qs sddm >/dev/null; then
        read -rp "GUI detected. Reinstall? (y/N): " rd
        [[ ! "$rd" =~ ^([yY])$ ]] && needs_de=false
    fi
    if [[ "$needs_de" == "true" ]]; then
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
    fi
}

install_drivers() {
    echo "--- Hardware Drivers ---"
    read -rp "Install hardware drivers? (y/N): " drv_ans
    if [[ "$drv_ans" =~ ^([yY])$ ]]; then
        echo "1) Standard X.Org 2) xLibre (Conflicting packages will be replaced)"
        read -rp "Driver preference: " drv_pref
        local pkgs=()
        local gpu_info=$(lspci)
        if echo "$gpu_info" | grep -qi "nvidia"; then
            if [[ "$drv_pref" == "2" ]]; then pkgs+=("xlibre-video-nouveau"); else pkgs+=("nvidia-dkms" "nvidia-utils"); fi
        fi
        if echo "$gpu_info" | grep -qi "intel"; then
            if [[ "$drv_pref" == "2" ]]; then pkgs+=("xlibre-video-intel"); else pkgs+=("xf86-video-intel" "intel-media-driver"); fi
        fi
        if echo "$gpu_info" | grep -qi "amd"; then
            if [[ "$drv_pref" == "2" ]]; then pkgs+=("xlibre-video-amdgpu" "vulkan-radeon"); else pkgs+=("xf86-video-amdgpu" "vulkan-radeon"); fi
        fi
        if grep -iq "oracle" /sys/class/dmi/id/sys_vendor 2>/dev/null || grep -iq "virtualbox" /proc/cpuinfo; then
            pacman -S --noconfirm virtualbox-guest-utils xf86-video-vmware
            pacman -S --noconfirm virtualbox-guest-utils-$INIT 2>/dev/null || true
        fi
        if [[ ${#pkgs[@]} -gt 0 ]]; then
            if [[ "$drv_pref" == "2" ]]; then
                pacman -S --noconfirm --needed "${pkgs[@]}" || pacman -S --noconfirm --nodeps "${pkgs[@]}"
            else
                pacman -S --noconfirm --needed "${pkgs[@]}" || true
            fi
        fi
    fi
}

install_bonus_tools() {
    echo "--- Bonus Tools ---"
    read -rp "Enter Extras Menu? (y/N): " bt_menu
    if [[ "$bt_menu" =~ ^([yY])$ ]]; then
        read -rp "Install Git & Base-Devel? (y/N): " i_git
        [[ "$i_git" =~ ^([yY])$ ]] && pacman -S --noconfirm git base-devel

        read -rp "Install Codecs? (y/N): " i_cod
        [[ "$i_cod" =~ ^([yY])$ ]] && pacman -S --noconfirm gst-plugins-good gst-libav

        read -rp "Install UFW? (y/N): " i_ufw
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
                pacman -S --noconfirm git base-devel && \
                git clone https://github.com/SashexSRB/rsvc /tmp/rsvc && {
                    cd /tmp/rsvc && make && make install && cd - >/dev/null && rm -rf /tmp/rsvc
                }
            fi
        fi

        read -rp "Install fastfetch? (y/N): " i_ff
        [[ "$i_ff" =~ ^([yY])$ ]] && pacman -S --noconfirm fastfetch
    fi
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
    read -rp "All done. Remove wizard? (y/N): " final
    [[ "$final" =~ ^([yY])$ ]] && { touch /var/lib/artix-firstboot-done; rm -f /etc/profile.d/firstboot.sh; }
}

main
