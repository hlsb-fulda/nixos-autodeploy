{ flake, pkgs, ... }:

pkgs.nixosTest {
  name = "auto-deploy";

  nodes.machine =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [ flake.nixosModules.default ];

      system.autoDeploy = {
        enable = true;
        interval = "hourly";

        # We use a flake wo can control via a symlink to simulate upstream changes
        fetch = pkgs.writers.writeBash "fetch" ''
          realpath -e /upstream
        '';

        prometheusFilePath = "/run/metrics/nixos-autodeploy.prom";
      };

      # To make `switch-to-configuration switch` work
      virtualisation.useBootLoader = true;

      services.prometheus.exporters.node = {
        enable = true;
        extraFlags = [ "--collector.textfile.directory=/run/metrics" ];
      };

      # Allow repeated start during tests
      systemd.services.nixos-autodeploy = {
        unitConfig.StartLimitIntervalSec = 0;
      };

      # Use specialisations to provide various system states to switch between
      specialisation.next.configuration = {
        environment.etc."test".text = "v1";
      };
    };

  testScript =
    { nodes, ... }:
    let
      base-system = nodes.machine.system.build.toplevel;
      next-system = nodes.machine.specialisation.next.configuration.system.build.toplevel;

      pne = "http://localhost:${toString nodes.machine.services.prometheus.exporters.node.port}/metrics";

    in
    ''
      machine.wait_for_unit("nixos-autodeploy.timer")

      with subtest("Service has started right after time"):
        # The first run fails, because upstream is a missing link, but we check
        # that the unit has run as it produced any kind of log
        machine.sleep(3)
        machine.succeed("journalctl -I -u nixos-autodeploy.service")

      with subtest("Missing state and same upstream"):
        current = machine.succeed("realpath -e /run/current-system").strip()
        assert current == "${base-system}"

        machine.succeed("rm -f /run/deployed-system")
        machine.succeed("ln -sfvnT '${base-system}' /upstream")

        machine.succeed("systemctl start --wait nixos-autodeploy.service")

        machine.shell_interact()

        output = machine.succeed("journalctl -I -u nixos-autodeploy.service -o cat")
        assert "Current system matches upstream" in output

        deployed = machine.succeed("realpath -e /run/deployed-system").strip()
        assert deployed == "${base-system}"

        machine.succeed("curl -s ${pne} | grep 'nixos_autodeploy_dirty 0'")

      with subtest("Missing state and differing upstream"):
        current = machine.succeed("realpath -e /run/current-system").strip()
        assert current == "${base-system}"

        machine.succeed("rm -f /run/deployed-system")
        machine.succeed("ln -sfvnT '${next-system}' /upstream")

        machine.succeed("systemctl start --wait nixos-autodeploy.service")

        output = machine.succeed("journalctl -I -u nixos-autodeploy.service -o cat")
        assert "Current system has been deployed manually" in output

        machine.succeed("! test -e /run/deployed-system")

        machine.succeed("curl -s ${pne} | grep 'nixos_autodeploy_dirty 1'")

      with subtest("Differing state and same upstream"):
        current = machine.succeed("realpath -e /run/current-system").strip()
        assert current == "${base-system}"

        machine.succeed("ln -sfvnT '${next-system}' /run/deployed-system")
        machine.succeed("ln -sfvnT '${base-system}' /upstream")

        machine.succeed("systemctl start --wait nixos-autodeploy.service")

        output = machine.succeed("journalctl -I -u nixos-autodeploy.service -o cat")
        assert "Current system matches upstream" in output

        deployed = machine.succeed("realpath -e /run/deployed-system").strip()
        assert deployed == "${base-system}"

        machine.succeed("curl -s ${pne} | grep 'nixos_autodeploy_dirty 0'")

      with subtest("Differing state and differing upstream"):
        current = machine.succeed("realpath -e /run/current-system").strip()
        assert current == "${base-system}"

        machine.succeed("ln -sfvnT '${next-system}' /run/deployed-system")
        machine.succeed("ln -sfvnT '${next-system}' /upstream")

        machine.succeed("systemctl start --wait nixos-autodeploy.service")

        output = machine.succeed("journalctl -I -u nixos-autodeploy.service -o cat")
        assert "Current system has been deployed manually" in output

        deployed = machine.succeed("realpath -e /run/deployed-system").strip()
        assert deployed == "${next-system}"

        current = machine.succeed("realpath -e /run/current-system").strip()
        assert current == "${base-system}"

        machine.succeed("curl -s ${pne} | grep 'nixos_autodeploy_dirty 1'")

      with subtest("Tracking state and same upstream"):
        current = machine.succeed("realpath -e /run/current-system").strip()
        assert current == "${base-system}"

        machine.succeed("ln -sfvnT '${base-system}' /run/deployed-system")
        machine.succeed("ln -sfvnT '${base-system}' /upstream")

        machine.succeed("systemctl start --wait nixos-autodeploy.service")

        output = machine.succeed("journalctl -I -u nixos-autodeploy.service -o cat")
        assert "System is up to date" in output

        machine.succeed("curl -s ${pne} | grep 'nixos_autodeploy_dirty 0'")

      with subtest("Tracking state and differing upstream"):
        current = machine.succeed("realpath -e /run/current-system").strip()
        assert current == "${base-system}"

        machine.succeed("ln -sfvnT '${base-system}' /run/deployed-system")
        machine.succeed("ln -sfvnT '${next-system}' /upstream")

        machine.succeed("systemctl start --wait nixos-autodeploy.service")

        output = machine.succeed("journalctl -I -u nixos-autodeploy.service -o cat")
        assert "Current system differs from upstream" in output

        deployed = machine.succeed("realpath -e /run/deployed-system").strip()
        assert deployed == "${next-system}"

        current = machine.succeed("realpath -e /run/current-system").strip()
        assert current == "${next-system}"

        machine.succeed("curl -s ${pne} | grep 'nixos_autodeploy_dirty 0'")

        # Reset back to base system
        machine.succeed("${base-system}/bin/switch-to-configuration switch")

      with subtest("Manual Deployment triggers run"):
        current = machine.succeed("realpath -e /run/current-system").strip()
        assert current == "${base-system}"

        machine.succeed("ln -sfvnT '${base-system}' /run/deployed-system")
        machine.succeed("ln -sfvnT '${base-system}' /upstream")

        machine.succeed("${next-system}/bin/switch-to-configuration switch")

        # Manually activating system should trigger the script
        output = machine.succeed("journalctl -I -u nixos-autodeploy.service -o cat")
        assert "Current system has been deployed manually" in output

        machine.succeed("curl -s ${pne} | grep 'nixos_autodeploy_dirty 1'")

        # Reset back to base system
        machine.succeed("${base-system}/bin/switch-to-configuration switch")
    '';
}
