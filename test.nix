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
        installable = "/tmp/upstream";

        prometheusFilePath = "/run/metrics/nixos-autodeploy.prom";
      };

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

      with subtest("Missing state and same upstream"):
        machine.succeed("rm -f /run/deployed-system")
        machine.succeed("ln -sfT '${base-system}' /tmp/upstream")

        machine.succeed("systemctl start --wait nixos-autodeploy.service")

        output = machine.succeed("journalctl -I -u nixos-autodeploy.service -o cat")
        assert "Current system matches upstream" in output

        deployed = machine.succeed("readlink -f /run/deployed-system").strip()
        assert deployed == "${base-system}"

        machine.succeed("curl -s ${pne} | grep 'nixos_autodeploy_dirty 0'")

      with subtest("Missing state and differing upstream"):
        machine.succeed("rm -f /run/deployed-system")
        machine.succeed("ln -sfT '${next-system}' /tmp/upstream")

        machine.succeed("systemctl start --wait nixos-autodeploy.service")

        output = machine.succeed("journalctl -I -u nixos-autodeploy.service -o cat")
        assert "Current system has been deployed manually" in output

        machine.succeed("! test -e /run/deployed-system")

        machine.succeed("curl -s ${pne} | grep 'nixos_autodeploy_dirty 1'")

      with subtest("Differing state and same upstream"):
        machine.succeed("ln -sfT '${next-system}' /run/deployed-system")
        machine.succeed("ln -sfT '${base-system}' /tmp/upstream")

        machine.succeed("systemctl start --wait nixos-autodeploy.service")

        output = machine.succeed("journalctl -I -u nixos-autodeploy.service -o cat")
        assert "Current system matches upstream" in output

        deployed = machine.succeed("readlink -f /run/deployed-system").strip()
        assert deployed == "${base-system}"

        machine.succeed("curl -s ${pne} | grep 'nixos_autodeploy_dirty 0'")

      with subtest("Differing state and differing upstream"):
        machine.succeed("ln -sfT '${next-system}' /run/deployed-system")
        machine.succeed("ln -sfT '${next-system}' /tmp/upstream")

        machine.succeed("systemctl start --wait nixos-autodeploy.service")

        output = machine.succeed("journalctl -I -u nixos-autodeploy.service -o cat")
        assert "Current system has been deployed manually" in output

        deployed = machine.succeed("readlink -f /run/deployed-system").strip()
        assert deployed == "${next-system}"

        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == "${base-system}"

        machine.succeed("curl -s ${pne} | grep 'nixos_autodeploy_dirty 1'")

      with subtest("Tracking state and same upstream"):
        machine.succeed("ln -sfT '${base-system}' /run/deployed-system")
        machine.succeed("ln -sfT '${base-system}' /tmp/upstream")

        machine.succeed("systemctl start --wait nixos-autodeploy.service")

        output = machine.succeed("journalctl -I -u nixos-autodeploy.service -o cat")
        assert "System is up to date" in output

        machine.succeed("curl -s ${pne} | grep 'nixos_autodeploy_dirty 0'")

      with subtest("Tracking state and differing upstream"):
        machine.succeed("ln -sfT '${base-system}' /run/deployed-system")
        machine.succeed("ln -sfT '${next-system}' /tmp/upstream")

        machine.succeed("systemctl start --wait nixos-autodeploy.service")

        output = machine.succeed("journalctl -I -u nixos-autodeploy.service -o cat")
        assert "Current system differs from upstream" in output

        deployed = machine.succeed("readlink -f /run/deployed-system").strip()
        assert deployed == "${next-system}"

        current = machine.succeed("readlink -f /run/current-system").strip()
        assert current == "${next-system}"

        # Reset back to base system
        machine.succeed("${base-system}/bin/switch-to-configuration test")

        machine.succeed("curl -s ${pne} | grep 'nixos_autodeploy_dirty 0'")
    '';
}
