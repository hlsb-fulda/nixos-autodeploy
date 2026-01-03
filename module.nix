{
  config,
  lib,
  utils,
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
    optional
    getExe
    ;

  cfg = config.system.autoDeploy;

in
{
  options.system.autoDeploy = {
    enable = mkEnableOption "Automatic NixOS system deployments";

    package = mkOption {
        type = types.package;
        description = ''
          The nixos-autodeployment package to use.
        '';
        default = pkgs.callPackage ./package.nix { };
    };

    url = mkOption {
      type = types.str;
      description = ''
        URL to fetch the containing the latest generation store-path.
      '';
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Extra arguments to pass to nixos-autodeploy.
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

    switchMode = mkOption {
      type = types.enum [ "switch" "boot" "smart" ];
      default = "switch";
      description = ''
        Determines how to switch to updated configuration.
        * switch: Switch to new configuration immediately
        * boot: Switch to new configuration on next reboot
        * smart: Switch to new configuration on next reboot, if the update contains a kernel update, immediately otherwise
      '';
    };

    rebootMode = mkOption {
        type = types.nullOr types.enum [ "reboot" "kexec" ];
        default = null;
        description = ''
          If not `null`, reboot the system automatically whenever required to apply the update.
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
        RUST_BACKTRACE = "full";
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = utils.escapeSystemdExecArgs (
          [
            (getExe cfg.package)
            cfg.url
          ]
          ++ (optional (cfg.prometheusFilePath != null) "--prometheus-path=${cfg.prometheusFilePath}")
          ++ cfg.extraArgs
        );
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
