# omarchy-unburdened
This is set of scripts to help create a lighter weight Omarchy installation with more options using the archinstall script. It makes it easy to remove all of the stuff that Omarchy automatically installs, leaving you with a clean, but highly functional hyprland setup that can serve as a base for building whatever system you like.


# Usage
These scripts are divided into three directories based on when they are intended to be run.

## run-before-arch-install
The goal of the run-before-arch-install script is it to provide easy access to more flexible partiting, dual boot, auto login (with an unencrypted drive) while still allowing you to set up bootable snapshots that default Omarchy provides. 


## run-after-arch-install 
This script sets up dependencies for limine snapper integration. This allows omarchy to create snapshots that can be booted into as a fallback if the primary boot option stops working.

## run-after-omarchy-script
To make post install cleanup easy, there is a script included that helps you figure out what omarchy automatically installed, a script that removes unwanted packages based on a packages.list file that you can modify, and a script that cleans up the launcher menu based on a desktop-entries.list file.