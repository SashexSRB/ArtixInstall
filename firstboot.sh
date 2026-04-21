#!/usr/bin/env bash
set -euo pipefail;

INIT="openrc";
[[ -d /run/runit ]] && INIT="runit";
[[ -d /run/dinit ]] && INIT="dinit";
[[ -d /run/s6    ]] && INIT="s6";

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

function _setup_networking {
    printf "--- Networking ---\n";
    if ping -c 1 8.8.8.8 &>/dev/null; then
        printf "[✓] Online.\n";
    else
        case "${INIT}" in
            openrc) rc-service iwd start 2>/dev/null || true ;;
            dinit)  dinitctl start iwd 2>/dev/null || true ;;
        esac
        sleep 2;
        iwctl;
    fi
}

function _enable_arch_repos {
    printf "--- Arch Repositories ---\n";
    if grep -q "^\[extra\]" /etc/pacman.conf; then
        printf "[✓] Already configured.\n";
    elif _ask "Enable Arch Repos?" "n"; then
        pacman -Sy --noconfirm artix-archlinux-support;
        hash -r;
        if [[ -f /usr/bin/artix-config-n-install ]]; then
            /usr/bin/artix-config-n-install && pacman-key --populate archlinux && pacman -Sy;
        else
            /usr/bin/artix-config-n-install 2>/dev/null && pacman-key --populate archlinux && pacman -Sy;
        fi
    fi
}

function _create_user {
    printf "--- User Setup ---\n";
    local un;
    printf "Username: "; read -r un;
    [[ -z "${un}" ]] && return 0;

    if id "${un}" &>/dev/null; then
        _ask "User '${un}' exists. Reset password?" "n" && passwd "${un}";
    else
        local ush="/bin/bash";
        _ask "Use Zsh instead of Bash?" "n" && { pacman -S --noconfirm zsh; ush="/bin/zsh"; };
        useradd -m -G wheel,audio,video,storage,input -s "${ush}" "${un}";
        passwd "${un}";
    fi
    pacman -S --noconfirm sudo;
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers 2>/dev/null || \
    sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers;
}

function _install_drivers {
    printf "--- Hardware Drivers ---\n";
    if _ask "Install hardware drivers?" "y"; then
        printf "1) Standard X.Org 2) xLibre\nChoice: "; 
        local drv_pref;
        read -r drv_pref;
        local pkgs=();
        local gpu_info;
        read -r gpu_info < <(lspci);
        
        if [[ "${gpu_info,,}" == *nvidia* ]]; then
            [[ "${drv_pref}" == "2" ]] && pkgs+=( "xlibre-video-nouveau" ) || pkgs+=( "nvidia-dkms" "nvidia-utils" );
        fi
        if [[ "${gpu_info,,}" == *intel* ]]; then
            [[ "${drv_pref}" == "2" ]] && pkgs+=( "xlibre-video-intel" ) || pkgs+=( "xf86-video-intel" "intel-media-driver" );
        fi
        if [[ "${gpu_info,,}" == *amd* ]]; then
            [[ "${drv_pref}" == "2" ]] && pkgs+=( "xlibre-video-amdgpu" "vulkan-radeon" ) || pkgs+=( "xf86-video-amdgpu" "vulkan-radeon" );
        fi
        
        if [[ "${#pkgs[@]}" -gt 0 ]]; then
            [[ "${drv_pref}" == "2" ]] && pacman -Rdd --noconfirm xorg-server 2>/dev/null || true;
            pacman -S --noconfirm --needed "${pkgs[@]}";
        fi
    fi
}

function _setup_audio {
    printf "--- Audio Setup ---\n";
    if pgrep -x "pipewire|pulseaudio" >/dev/null; then
        _ask "Audio server detected. Reconfigure?" "n" || return 0;
    fi

    if _ask "Configure audio (Pipewire/Pulse)?" "y"; then
        printf "1) Pipewire 2) PulseAudio\nChoice: ";
        local ac;
        read -r ac;
        case "${ac}" in
            1) pacman -S --noconfirm pipewire pipewire-pulse wireplumber && pacman -S --noconfirm "pipewire-${INIT}" 2>/dev/null || true ;;
            2) pacman -S --noconfirm pulseaudio pulseaudio-alsa && pacman -S --noconfirm "pulseaudio-${INIT}" 2>/dev/null || true ;;
        esac
    fi
}

function _setup_desktop {
    printf "--- Desktop Environment ---\n";
    
    if ! _ask "Install a Desktop Environment?" "n"; then
        printf "[!] Skipping Desktop Environment. System will remain CLI only.\n";
        return 0;
    fi

    local current_dm=1;
    if pacman -Qs lightdm >/dev/null || pacman -Qs sddm >/dev/null; then
        _ask "GUI detected. Reinstall?" "n" || current_dm=0;
    fi

    if [[ "${current_dm}" -eq 1 ]]; then
        printf "1) XFCE4 2) LXQt 3) LXDE 4) None\nDE: ";
        local dc;
        read -r dc;
        local pkgs="" dm="lightdm";
        local common="network-manager-applet gvfs gvfs-mtp";

        case "${dc}" in
            1) pkgs="xfce4 xfce4-goodies ${common}" ;;
            2) pkgs="lxqt pavucontrol-qt ${common}" ;;
            3) pkgs="lxde lxappearance ${common}" ;;
            *) return 0 ;;
        esac

        if [[ "${dc}" == "2" || "${dc}" == "3" ]]; then
            _ask "Use SDDM instead of LightDM?" "n" && dm="sddm";
        fi

        pacman -S --noconfirm ${pkgs} ${dm} "${dm}-${INIT}";
        [[ "${dm}" == "lightdm" ]] && pacman -S --noconfirm lightdm-gtk-greeter;

        case "${INIT}" in
            openrc) rc-update add "${dm}" default 2>/dev/null || true ;;
            runit)  ln -s "/etc/runit/sv/${dm}" /etc/runit/runsvdir/default/ 2>/dev/null || true ;;
            dinit)  mkdir -p /etc/dinit.d/boot.d; ln -s "../${dm}" /etc/dinit.d/boot.d/ 2>/dev/null || true ;;
            s6)     s6-rc-bundle-update add default "${dm}" 2>/dev/null || true ;;
        esac
    fi
}

function _install_bonus_tools {
    printf "--- Bonus Tools ---\n";
    if _ask "Enter Extras Menu?" "n"; then
        _ask "Install Git & Base-Devel?" "y" && pacman -S --noconfirm git base-devel;
        _ask "Install Codecs?" "n" && pacman -S --noconfirm gst-plugins-good gst-libav;
        
        if _ask "Install UFW (Firewall)?" "y"; then
            pacman -S --noconfirm ufw "ufw-${INIT}";
            case "${INIT}" in
                openrc) rc-update add ufw default ;;
                dinit)  ln -s ../ufw /etc/dinit.d/boot.d/ ;;
            esac
        fi

        _ask "Install Bluetooth?" "n" && { pacman -S --noconfirm bluez "bluez-${INIT}"; };
        _ask "Install Flatpak?" "n" && pacman -S --noconfirm flatpak;
        _ask "Install Fastfetch?" "y" && pacman -S --noconfirm fastfetch;
        _ask "Install Zram?" "n" && { pacman -S --noconfirm "zramen-${INIT}" 2>/dev/null || pacman -S --noconfirm zram-tools 2>/dev/null || true; };

        if [[ "${INIT}" == "runit" ]]; then
            if _ask "Install rsvc (SashexSRB)?" "n"; then
                pacman -S --noconfirm git base-devel;
                git clone https://github.com /tmp/rsvc && {
                    pushd /tmp/rsvc >/dev/null && make && make install && popd >/dev/null && rm -rf /tmp/rsvc;
                };
            fi
        fi
    fi
}

function main {
    [[ "${EUID}" -ne 0 ]] && _error_exit "This script must be run as root. Use 'sudo /usr/local/bin/firstboot.sh'";

    clear;
    printf "=======================================\n";
    printf "   ARTIX POST-INSTALL WIZARD           \n";
    printf "=======================================\n";
    _setup_networking;
    _enable_arch_repos;
    _create_user;
    _install_drivers;
    _setup_audio;
    _setup_desktop;
    _install_bonus_tools;
    
    if _ask "All done. Remove wizard?" "y"; then
        touch /var/lib/artix-firstboot-done;
        rm -f /etc/profile.d/firstboot.sh;
        printf "[*] Wizard removed. Reboot or logout to apply all changes.\n";
    fi
}

main;
