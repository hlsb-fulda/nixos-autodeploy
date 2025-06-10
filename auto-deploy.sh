#!/usr/bin/env bash

set -euo pipefail

if [ -z "${AUTODEPLOY_INSTALLABLE:-}" ]; then
  echo "AUTODEPLOY_INSTALLABLE not set">&2
  exit 1
fi

# Read in current state
current_drv="$(readlink -f /run/current-system)"
deployed_drv="$(readlink -f /run/deployed-system || echo "")"

# Update upstream derivation and register as GC root
upstream_drv="$(nix --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths "${AUTODEPLOY_INSTALLABLE}")"
ln -sfT "${upstream_drv}" /run/upstream-system
ln -sfT /run/upstream-system /nix/var/nix/gcroots/upstream-system

# The dirty state tracks, if the system has been deployed manually and differs
# from upstream, thus preventing automatic deployments
dirty=0

# Do the automatic deployment
# There are four states depending on the comparison of current, deployed and upstream derivations
# | current == deployed | current == upstream | action             |
# |---------------------|---------------------|--------------------|
# |         ❌          |         ❌          | suspend            |
# |         ❌          |         ✅          | start tracking     |
# |         ✅          |         ❌          | perform deployment |
# |         ✅          |         ✅          | nothing to do      |
if [ "${current_drv}" != "${deployed_drv}" ]; then
  if [ "${current_drv}" == "${upstream_drv}" ]; then
    echo "🐾Current system matches upstream - start tracking upstream by syncing delpoyed state"
    ln -sfT "${current_drv}" /run/deployed-system
  else
    echo "😾Current system has been deployed manually - skipping deployment"
    dirty=1
  fi
else
  if [ "${current_drv}" != "${upstream_drv}" ]; then
    echo "🚚Current system differs from upstream - deploying upstream"
    systemd-run \
      -E NIXOS_INSTALL_BOOTLOADER=1 \
      --collect \
      --no-ask-password \
      --pipe \
      --quiet \
      --service-type=exec \
      --unit=nixos-autodeploy-switch-to-configuration \
      --wait \
      "${upstream_drv}/bin/switch-to-configuration" switch
    ln -sfT "${upstream_drv}" /run/deployed-system
  else
    echo "🤩System is up to date"
  fi
fi

# Check if the system needs a reboot for full update
reboot_required=0
if [ "$(readlink /run/booted-system/{initrd,kernel,kernel-modules})" != "$(readlink /run/current-system/{initrd,kernel,kernel-modules})" ]; then
  echo "⏳Reboot required"
  reboot_required=1
fi

# Expose deployment status to prometheus node exporter
if [ -n "${AUTODEPLOY_PROM_PATH:-}" ]; then
  mkdir -p "$(dirname "${AUTODEPLOY_PROM_PATH}")"
  sponge "${AUTODEPLOY_PROM_PATH}" <<EOF
# HELP nixos_autodeploy_dirty 1 if system is not tracking upstream
# TYPE nixos_autodeploy_dirty gauge
nixos_autodeploy_dirty $dirty

# HELP nixos_autodeploy_reboot_required 1 if system needs to be restarted for full update
# TYPE nixos_autodeploy_reboot_required gauge
nixos_autodeploy_reboot_required $reboot_required
EOF
fi

