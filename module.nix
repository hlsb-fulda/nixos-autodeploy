{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkIf
    mkOption
    mkEnableOption
    types
    literalExpression
    getExe
    ;

  cfg = config.system.autoDeploy;

  script = pkgs.writeShellApplication {
    name = "nixos-auto-deploy";
    runtimeInputs = with pkgs; [
      coreutils
      moreutils
      nix
      systemd
    ];
    text = builtins.readFile ./auto-deploy.sh;
  };

in
{
  options.system.autoDeploy = {
    enable = mkEnableOption "Automatic NixOS system deployments";

    installable = mkOption {
      type = types.str;
      description = ''
        The system installable to track and deploy.
      '';
      default = "${cfg.flake}#nixosConfigurations.${config.networking.hostName}.config.system.build.toplevel";
      defaultText = literalExpression "\${config.system.autodeploy.flake}#nixosConfigurations.\${config.networking.hostName}.config.system.build.toplevel";
      example = "github:fooker/nixcfg#colmenaHive.nodes.mynode.config.specialisation.example.config.system.build.toplevel";
    };

    flake = mkOption {
      type = types.str;
      example = "github:kloenk/nix";
      description = ''
        The Flake URI of the NixOS configuration to deploy.
        Only used if `system.autodeploy.installable` is not set.
      '';
    };

    interval = mkOption {
      type = types.str;
      default = "04:42";
      example = "daily";
      description = ''
        How often or when upgrade occurs. For most desktop and server systems
        a sufficient upgrade frequency is once a day.

        The format is described in
        {manpage}`systemd.time(7)`.
      '';
    };

    randomizedDelay = mkOption {
      type = types.str;
      default = "0";
      example = "45min";
      description = ''
        Add a randomized delay before each automatic upgrade.
        The delay will be chosen between zero and this value.
        This value must be a time span in the format specified by
        {manpage}`systemd.time(7)`
      '';
    };

    prometheusFilePath = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/var/lib/prometheus-node-exporter/text-files/nixos-autodeploy.prom";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.nixos-autodeploy = {
      description = "NixOS auto-deployment";

      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # Do not restart the unit as it might be currently running the
      # activation leading to the config change.
      restartIfChanged = false;

      environment = {
        AUTODEPLOY_INSTALLABLE = cfg.installable;
        AUTODEPLOY_PROM_PATH = cfg.prometheusFilePath;
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = getExe script;
      };
    };

    systemd.timers.nixos-autodeploy = {
      description = "NixOS auto-deployment";

      wantedBy = [ "timers.target" ];

      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      timerConfig = {
        OnCalendar = [ cfg.interval ];

        OnStartupSec = "0sec";

        RandomizedDelaySec = cfg.randomizedDelay;
        FixedRandomDelay = true;

        Persistent = true;
      };
    };

    # Trigger a deployment run after activation
    system.activationScripts.nixos-autodeploy = ''
      if [ -d "/run/nixos" ]; then
        echo "nixos-autodeploy.service" > /run/nixos/activation-restart-list
      fi
    '';
  };
}
