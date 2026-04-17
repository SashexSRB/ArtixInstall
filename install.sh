#!/bin/bash
set -euo pipefail

MODE=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#################
# ARG PARSING
#################

for arg in "$@"; do
    case "$arg" in
    -a | --auto)
        MODE="auto"
        ;;
    -m | --manual)
        MODE="manual"
        ;;
    -h | --help)
        echo "Usage:"
        echo "  ./install -a (--auto)     Run automatic installer"
        echo "  ./install -m (--manual)   Run manual installer"
        exit 0
        ;;
    *)
        echo "[ERROR] Unknown option: $arg"
        echo "Usage:"
        echo "  ./install -a (--auto)"
        echo "  ./install -m (--manual)"
        exit 1
        ;;
    esac
done

#################
# REQUIRE MODE
#################

if [[ -z "$MODE" ]]; then
    echo "[ERROR] No mode selected."
    echo
    echo "You must specify one of:"
    echo "  -a (--auto)"
    echo "  -m (--manual)"
    exit 1
fi

#################
# DISPATCH
#################

if [[ "$MODE" == "manual" ]]; then
    if [[ ! -f "$SCRIPT_DIR/scripts/install_manual.sh" ]]; then
        echo "[ERROR] install_manual.sh not found in scripts/"
        exit 1
    fi

    exec bash "$SCRIPT_DIR/scripts/install_manual.sh"

elif [[ "$MODE" == "auto" ]]; then
    if [[ ! -f "$SCRIPT_DIR/scripts/install_auto.sh" ]]; then
        echo "[ERROR] install_auto.sh not found in scripts/"
        exit 1
    fi

    exec bash "$SCRIPT_DIR/scripts/install_auto.sh"
fi
