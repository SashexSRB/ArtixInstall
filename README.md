# ArtixInstall

Artix Linux installation script. Intended for anyone willing to try out Artix without the hassle.

Fork of [SashexSRB/ArtixInstall](https://github.com/SashexSRB/ArtixInstall). 
## Overview

This script automates Artix Linux installation while adhering to UNIX philosophy principles: modularity, plain text interfaces, and small focused tools that pipe together.

Everything is up to the user's choice.

## Features

**NEWEST FEATURE(S)**: BTRFS & LUKS support

**Init systems**: OpenRC, runit, s6, dinit

**Display drivers**: Includes Xlibre drivers and Xorg, up for taste of the user.

**Security**: Optional LUKS encryption.

**Storage:** BTRFS or EXT4.

**Network**: Ethernet default. Installs iwd, wpa_supplicant, and dhcpcd.

**Bootloaders**: Grub and rEFind (UEFI).

**Kernels**: Baseline Linux Kernel *(for now)*

**Desktop environments**: Selectable during post-install *(XFCE4, LXQt, LXDE)*

## Requirements

- Artix Linux live environment *(any init system)*

- Internet connectivity

- Git 

## Installation
    bash

    git clone https://github.com/MadeInAmbrosia/ArtixInstall
    cd ArtixInstall
    chmod +x install
    sudo ./install -h

## What the script does

- Verifies network connectivity

- Prompts for target disk with two options:

- Automatic: Script partitions the disk

- Manual: User pre-partitions before running script

- Presents configuration options for init system, kernel and bootloader

- Installs base system

- Installs iwd, wpa_supplicant, and dhcpcd

- Configures first-boot scripts for driver and service finalization.

## Post-install

- First boot triggers firstboot.sh, which handles:

- Driver installation (including Xlibre where applicable)

- Service enabling based on selected init system

- WiFi configuration via iwd

- Allows the user to choose to enable arch repos

- Creates the user, installs drivers of choice, sets up audio, the DE

- Contains bonus tools such as Git and base-devel, Codecs, UFW, Bluetooth, Flatpak, Zram, Fastfetch, (runit only) SashexSRB's rsvc.

## Script structure
### File	Purpose
*install* -	Main installation routine

*firstboot.sh* - Post-install configuration on first boot

*firstboot_trigger.sh* -	Trigger mechanism for firstboot.sh

*scripts/* - Manual and Auto scripts for base-line installation

## Maintenance

Actively maintained and tested for every new feature added.

Any bugs should be reported either here on Github or via contacting *volk.v* on Discord.

## Credits

#### Original: [SashexSRB](https://github.com/SashexSRB)
#### Current maintainer: [MadeInAmbrosia](https://github.com/MadeInAmbrosia)

