#!/bin/zsh
# Copy the addon into the local WoW Forever client (copy, not symlink).
set -e
cd "$(dirname "$0")"
luajit tests/sim.lua | tail -1 | grep -q "ALL PASS" || { echo "tests fail; not installing"; exit 1; }
dest="/Applications/World of Warcraft/_forever_/Interface/AddOns/Moonwardens"
rm -rf "$dest"
cp -R Moonwardens "$dest"
echo "installed to $dest"
