# NixOS Auto-Deployment
A robust NixOS system auto-deployment for continues integration.

`nixos-autodeploy` implements the pull-model by fetching the latest system path from a URL and then realizes the system from caches.
This integrates well with CI workflows.

While to pull-model is used for automatic updates, `nixos-autodeploy` integrates well with push-model tools like colmena or even good old `nixos-rebuild` by stopping automatic updates when the current system diverges from upstream.

This module provides:

* Automatic polling and switching to updated system flake configurations
* Derivation-based comparison and update gating
* Upstream preview via `/run/upstream-system`
* Prometheus metrics integration

## Comparison to other tools
* `system.autoUpgrade` relies on local channels or flake locks that are updated locally.
* [comin](https://github.com/nlewo/comin) has a far more elaborated branching scheme but does not integrate well with push-model tools.

## Features
* 🛡 **Safe-by-default**: system updates only apply if the current system matches a previous deployment.
* 🔐 **Aware of manual deployment**: integrates with colmena (or other push-based deployment tools) workflows; updates are suspended until system state is clean.
* 📊 **Prometheus metrics**: Writes a `.prom` file to use by prometheus node exporter.
* ♻ **GC-safe**: `/run/upstream-system` is pinned as a GC root for inspection or rollback.

## Requirements
`nixos-autodeploy` requires an existing CI pipeline and a nix binary cache.
The CI pipeline must build the system to deploy and push the resulting system path to the cache.
After cache deployment, the CI pipeline must publish an artifact containing the system path somewhere readable by HTTP GET requests.
The target system must be configured to user this binary cache.

## Usage
This contains a ready-to-use NixOS module that can be included either as flake or by importing the `module.nix` file.

```nix
{
  inputs.autodeploy.url = "github:hlsb-fulda/nixos-autodeploy";

  outputs = { self, nixpkgs, autodeploy, ... }:
    {
      nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          autodeploy.nixosModules.default
          ({ pkgs, config, ... }: {
            system.autoDeploy = {
              enable = true;
              url = "http://example.com/upstream";
              interval = "15min";
            };
          })
        ];
      };
    };
}
```

## Activation modes and rebooting
`nixos-autodeploy` supports multiple modes determined by the `switchMode` and `rebootMode` options.

`switchMode` describes the way a new configuration is updated:
- `switch`: Always switch to the new configuration immediately.
- `boot`: Always switch to new configuration on next boot.
- `smart`: Determine if the new configuration contains a change to the kernel, initrd or modules. It switches to the new configuration on newt boot, if the kernel has changed and immediately otherwise.

`rebootMode` describes if and how the system should automatically reboot:
- `null`: Do no reboot automatically.
- `reboot`: Reboot the system.
- `kexec`: Activate new kernel using kexec.

## Module reference
### `system.autoDeploy.enable`
**Type**: bool \
Enable the auto-deployment integration.

### `system.autoDeploy.package`
**Type**: package \
**Default**: *The tool provided by this module* \
The package containing the `nixos-autodeploy` tool.

### `system.autoDeploy.url`
**Type**: string \
The URL to fetch the latest systemc path from.
This URL must respond to a GET request with a single line string containing a nix store path.

### `system.autoDeploy.extraArgs`
**Type**: list of strings \
**Default**: `[]` \
Additional arguments passed to the `nixos-autodeploy` tool.

### `system.autoDeploy.interval`
**Type**: string \
**Default**: `"04:42"` \
How often or when upgrade occurs.
For most desktop and server systems  a sufficient upgrade frequency is once a day. \
The format is described in [systemd.time(7)](https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html).

### `system.autoDeploy.randomizedDelay`
**Type**: string \
**Default**: `"0"` \
Add a randomized delay before each automatic upgrade.
The delay will be chosen between zero and this value.
This value must be a time span in the format specified by
[systemd.time(7)](https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html).

### `system.autoDeploy.switchMode`
**Type**: on off `"switch"`, `"boot"` or `"smart"` \
**Default**: `"switch"` \
Determines how to switch to updated configuration.
See [Activation modes and rebooting](#activation-modes-and-rebooting).

### `system.autoDeploy.rebootMode`
**Type**: `null` or on off `"reboot"` or `"kexec"` \
**Default**: `null` \
If not `null`, reboot the system automatically whenever required to apply the update.
See [Activation modes and rebooting](#activation-modes-and-rebooting).

### `system.autoDeploy.rebootMode`
**Type**: `null` or string \
**Default**: `null` \
If not `null`, write [prometheus metrics](#prometheus-metrics) to this path.

## Prometheus metrics
`nixos-autodeply` can write a prometheus metrics file that can be collected by [Prometheus Node Exporter](https://github.com/prometheus/node_exporter).

The following metrics are exported:
* `nixos_autodeploy_dirty`: set to 1 when current system differs from tracking system by manual deployment.
* `nixos_autodeploy_reboot_required`: set to 1 when booted kernel != current kernel.
* `nixos_autodeploy_info`: details about the current system paths.
