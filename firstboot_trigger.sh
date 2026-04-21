#!/usr/bin/env bash
set -euo pipefail;

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

function main {
    if [[ -f /var/lib/artix-firstboot-done ]]; then
        [[ "${EUID}" -eq 0 ]] && rm -f /etc/profile.d/firstboot.sh 2>/dev/null;
        return 0;
    fi

    [[ ! -f /usr/local/bin/firstboot.sh ]] && return 0;

    clear;
    printf "=======================================\n";
    printf "   ARTIX POST-INSTALLATION WIZARD      \n";
    printf "=======================================\n";
    printf "It looks like this is your first boot.\n";
    printf "The system is now ready for final setup.\n";
    printf "---------------------------------------\n";
    printf "This wizard will help you with:\n";
    printf " - Network connectivity (Wi-Fi)\n";
    printf " - User creation (with your chosen shell)\n";
    printf " - Graphics and Desktop Environment\n";
    printf " - Extra tools and drivers\n";
    printf "=======================================\n\n";

    if _ask "Run setup now?" "y"; then
        printf "[*] Launching firstboot script...\n";o
        if [[ "${EUID}" -eq 0 ]]; then
            exec /usr/local/bin/firstboot.sh;
        else
            exec sudo /usr/local/bin/firstboot.sh;
        fi
    else
        printf "[*] Skipping setup for now.\n";
        printf "[*] To prevent this prompt, create /var/lib/artix-firstboot-done\n";
        printf "    or run the wizard later from /usr/local/bin/firstboot.sh\n";
    fi
}


main;
