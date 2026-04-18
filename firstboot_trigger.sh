#!/bin/bash

# =======================================================
#   ARTIX POST-INSTALL TRIGGER (profile.d)
# =======================================================

# Privilege check
if [[ "$EUID" -ne 0 ]]; then
    return
fi

# Setup already done?
if [[ -f /var/lib/artix-firstboot-done ]]; then
    # Lock exists?
    rm -f /etc/profile.d/firstboot.sh 2>/dev/null
    return
fi

# Firstboot.sh exists?
if [[ ! -f /usr/local/bin/firstboot.sh ]]; then
    return
fi

# Echo the prompt
clear
echo "======================================="
echo "   ARTIX POST-INSTALLATION WIZARD      "
echo "======================================="
echo "It looks like this is your first boot."
echo "The system is now ready for final setup."
echo "---------------------------------------"
echo "This wizard will help you with:"
echo " - Network connectivity (Wi-Fi)"
echo " - User creation (with your chosen shell)"
echo " - Graphics and Desktop Environment"
echo "======================================="
echo

read -rp "Run setup now? [y/N]: " CHOICE

case "$CHOICE" in
    [yY][eE][sS]|[yY])
        echo "[*] Launching firstboot script..."
        /usr/local/bin/firstboot.sh
        ;;
    *)
        echo "[*] Skipping setup for now."
        echo "[*] To prevent this prompt, create /var/lib/artix-firstboot-done"
        echo "    or run the wizard later from /usr/local/bin/firstboot.sh"
        ;;
esac
