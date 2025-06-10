# NixOS Auto-Deployment
A robust NixOS system auto-deployment.

This module provides:

* Automatic polling and switching to updated system flake configurations
* Derivation-based comparison and update gating
* Upstream preview via `/run/upstream-system`
* Prometheus metrics integration

## Features

* 🛡 **Safe-by-default**: system updates only apply if the current system matches a previous deployment
* 🔐 **Aware of manual deployment**: integrates with colmena (or other push-based deployment tools) workflows; updates are suspended until system state is clean
* 📊 **Prometheus metrics**:
  * Writes a `.prom` file to use by prometheus node exporter (use `prometheusFilePath` to enable)
  * `nixos_autodeploy_dirty`: set to 1 when current system differs from tracking system by manual deployment
  * `nixos_autodeploy_reboot_required` set to 1 when booted kernel != current kernel
* ♻ **GC-safe**: `/run/upstream-system` is pinned as a GC root for inspection or rollback

## Usage

```nix
{
  inputs.autodeploy.url = "github:hlsb-fulda/nixos-autodeploy";

  outputs = { self, nixpkgs, autodeploy, ... }:
    {
      nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          autodeploy.nixosModules.default
          {
            system.autoDeploy = {
              enable = true;
              flake = "github:yourorg/yourflake";
              interval = "15min";
            };
          }
        ];
      };
    };
}
```
