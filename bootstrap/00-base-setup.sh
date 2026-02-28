#!/bin/bash
set -e

echo "=== Fix broken packages (if any) ==="
sudo apt --fix-broken install -y || true

echo "=== System Update ==="
sudo apt update

echo "=== Upgrade packages ==="
sudo apt upgrade -y || true

echo "=== Install Base Tools ==="
sudo apt install -y \
    curl \
    git \
    htop \
    nano \
    ca-certificates \
    gnupg

echo "=== Enable unattended upgrades ==="
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -f noninteractive unattended-upgrades

echo "=== Base setup complete ==="
