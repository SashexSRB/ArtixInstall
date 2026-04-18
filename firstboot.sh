#!/bin/bash
set -euo pipefail

# INIT Detection
# We're trying to detect which INIT system is being used (Changed from Serbian)
INIT="openrc"
if [ -d /run/runit ]; then 
    INIT="runit"
elif [ -d /run/dinit ]; then 
    INIT="dinit"
elif [ -d /run/s6 ]; then 
    INIT="s6" 
fi

setup_network() {
    echo "[*] Checking for internet connectivity..."
    if ping -c 1 8.8.8.8 &>/dev/null; then
        echo "[✓] Online."
        return 0
    fi

    # Start iwd service
    case "$INIT" in
        openrc) rc-service iwd start 2>/dev/null || true ;;
        dinit)  dinitctl start iwd 2>/dev/null || true ;;
    esac
    
    echo "[!] Offline. Launching iwctl for Wi-Fi setup..."
    sleep 2
    iwctl
}

create_user() {
    local USERNAME
    echo "--- User Account Setup ---"
    read -rp "Enter new username: " USERNAME
    
    if [[ -z "$USERNAME" ]]; then
        echo "[ERROR] Username cannot be empty."
        exit 1
    fi

    # Shell logic EDIT: I forgot to change commments to English.
    local FINAL_SHELL="/bin/bash"
    if [[ -f /tmp/shell_choice ]]; then
        FINAL_SHELL=$(cat /tmp/shell_choice)
        echo "[*] Using selected shell: $FINAL_SHELL"
    fi

    # User creation
    useradd -m -G wheel,audio,video,storage,input -s "$FINAL_SHELL" "$USERNAME"
    echo "[*] Setting password for $USERNAME:"
    passwd "$USERNAME"

    # Sudo configuration
    echo "[*] Configuring sudo privileges..."
    if ! command -v sudo &>/dev/null; then
        pacman -Sy --noconfirm sudo
    fi

    # Wheel group
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers 2>/dev/null || \
    sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers
}

install_gui() {
    echo "--- Graphics & Desktop Environment ---"
    echo "1) XFCE4  2) LXQt  3) LXDE  4) None"
    read -rp "Selection [1-4]: " GUI_CHOICE

    local PKGS=""
    local SERVICE="lightdm"

    case "$GUI_CHOICE" in
        1) PKGS="xfce4 xfce4-goodies lightdm lightdm-gtk-greeter lightdm-$INIT" ;;
        2) PKGS="lxqt sddm sddm-$INIT" ; SERVICE="sddm" ;;
        3) PKGS="lxde sddm sddm-$INIT" ; SERVICE="sddm" ;;
        *) return 0 ;;
    esac

    echo "[*] Installing GUI packages..."
    pacman -S --noconfirm $PKGS

    echo "[*] Enabling $SERVICE service for $INIT..."
    case "$INIT" in
        openrc) rc-update add $SERVICE default ;;
        runit)  ln -s /etc/runit/sv/$SERVICE /etc/runit/runsvdir/default/ ;;
        dinit)  
            mkdir -p /etc/dinit.d/boot.d
            ln -s ../$SERVICE /etc/dinit.d/boot.d/ 
            ;;
        s6)     s6-rc-bundle-update add default $SERVICE ;;
    esac
}

main() {
    echo "======================================="
    echo "   ARTIX LINUX POST-INSTALL SETUP      "
    echo "======================================="

    setup_network
    create_user
    install_gui

    # Cleanup
    echo "[*] Cleaning up post-install files..."
    touch /var/lib/artix-firstboot-done
    rm -f /etc/profile.d/firstboot.sh
    rm -f /tmp/shell_choice 2>/dev/null || true
    
    echo "======================================="
    echo "[✓] POST-INSTALL COMPLETE!"
    echo "You can now log out and log in as your new user."
    echo "======================================="
}

main
