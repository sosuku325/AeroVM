#!/bin/bash
# Entrypoint for the "shell" debug image: prints the marker Pterodactyl waits
# for, then hands the console over to an interactive shell. No VM is started.
set -u

echo "Starting AeroVM"
echo "INFO: shell image — no VM is running. Your server files are in /home/container."
echo "INFO: tools available: qemu-img, xorriso, curl"

cd /home/container
exec bash -i
