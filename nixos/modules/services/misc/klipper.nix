{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.services.klipper;
  format = pkgs.formats.ini {
    # https://github.com/NixOS/nixpkgs/pull/121613#issuecomment-885241996
    listToValue = l:
      if builtins.length l == 1 then generators.mkValueStringDefault { } (head l)
      else lib.concatMapStrings (s: "\n  ${generators.mkValueStringDefault {} s}") l;
    mkKeyValue = generators.mkKeyValueDefault { } ":";
  };
  flattenConfig =
    let
      attrsToFlatten = [ "include" ];
      flattenAttr = prfx: attr: pipe attr [
        # convert lists to empty attrsets
        (v:
          if (isList v)
          then genAttrs v (_: { })
          else v
        )
        # prefix attribute names
        (mapAttrs'
          (name: nameValuePair "${prfx} ${name}")
        )
      ];
    in
    input: pipe attrsToFlatten [
      # build a list of flattend attributes
      (map
        (prfx: flattenAttr prfx (input.${prfx} or { }))
      )
      # merge the list of flattened attributes with input
      (attrList: attrsets.mergeAttrsList (attrList ++ [ input ]))
      # remove flattened attributes
      (filterAttrs
        (name: _: ! (elem name attrsToFlatten))
      )
    ];
  baseServiceConfig = {
    StateDirectory = "klipper";
    DynamicUser = true;
    User = "klipper";
  } // (optionalAttrs (cfg.user != null) {
    DynamicUser = false;
    User = cfg.user;
    Group = cfg.group;
  });
in
{
  ##### interface
  options = {
    services.klipper = {
      enable = mkEnableOption "Klipper, the 3D printer firmware";

      package = mkPackageOption pkgs "klipper" { };

      logFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/var/lib/klipper/klipper.log";
        description = ''
          Path of the file Klipper should log to.
          If `null`, it logs to stdout, which is not recommended by upstream.
        '';
      };

      inputTTY = mkOption {
        type = types.path;
        default = "/run/klipper/tty";
        description = "Path of the virtual printer symlink to create.";
      };

      apiSocket = mkOption {
        type = types.nullOr types.path;
        default = "/run/klipper/api";
        description = "Path of the API socket to create.";
      };

      apiServer = {
        enable = mkEnableOption "Moonraker API server";

        address = mkOption {
          type = types.nullOr types.str;
          default = "127.0.0.1";
          example = "0.0.0.0";
          description = "The IP or host to listen on.";
        };


        port = mkOption {
          type = types.port;
          default = 7125;
          description = "The port to listen on.";
        };

        allowSystemControl = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Whether to allow Moonraker to perform system-level operations.

            Moonraker exposes APIs to perform system-level operations, such as
            reboot, shutdown, and management of systemd units. See the
            [documentation](https://moonraker.readthedocs.io/en/latest/web_api/#machine-commands)
            for details on what clients are able to do.
          '';
        };

        settings = mkOption {
          type = format.type;
          default = { };
          example = {
            authorization = {
              trusted_clients = [ "10.0.0.0/24" ];
              cors_domains = [ "https://app.fluidd.xyz" "https://my.mainsail.xyz" ];
            };
          };
          description = ''
            Configuration for Moonraker. See the [documentation](https://moonraker.readthedocs.io/en/latest/configuration/)
            for supported values.
          '';
        };

        octoprintCompat = mkEnableOption "Octoprint compatability";
      };

      # DEPRECATED use mutableSettings
      mutableConfig = mkOption {
        type = types.bool;
        default = false;
        example = true;
        visible = false;
        description = ''
          Whether to copy the config to a mutable directory instead of using the one directly from the nix store.
          This will only copy the config if the file at `services.klipper.mutableConfigPath` doesn't exist.
        '';
      };

      mutableConfigFolder = mkOption {
        type = types.path;
        default = "/var/lib/klipper";
        description = "Path to copy mutable Klipper config file to.";
      };

      immutableConfigPath = mkOption {
        type = types.path;
        default = "${cfg.mutableConfigFolder}/printer-immutable.cfg";
        description = ''
          Path to link to immutable config generated from settings.
          
          This will be automatically included in the mutable config file.
        '';
      };

      configFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to default Klipper config.
        '';
      };

      octoprintIntegration = mkOption {
        type = types.bool;
        default = false;
        description = "Allows Octoprint to control Klipper.";
      };

      user = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          User account under which Klipper runs.

          If null is specified (default), a temporary user will be created by systemd.
        '';
      };

      group = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Group account under which Klipper runs.

          If null is specified (default), a temporary user will be created by systemd.
        '';
      };

      settings = mkOption {
        type = types.submodule {
          freeformType = format.type;
          options = {
            include = mkOption {
              type = types.listOf types.path;
              default = [ ];
              description = lib.mdDoc ''
                List of paths to be included in the klipper config
              '';
            };
          };
        };
        default = null;
        description = ''
          Configuration for Klipper. See the [documentation](https://www.klipper3d.org/Overview.html#configuration-and-tuning-guides)
          for supported values.
        '';
      };

      mutableSettings = mkOption {
        type = format.type;
        default = { };
        description = lib.mdDoc ''
          Mutable configuration for Klipper. See the [documentation](https://www.klipper3d.org/Overview.html#configuration-and-tuning-guides)
          for supported values. These settings will be copied to klippers config directory if it doesn't already exist.
        '';
      };

      firmwares = mkOption {
        description = "Firmwares klipper should manage";
        default = { };
        type = with types; attrsOf
          (submodule {
            options = {
              enable = mkEnableOption ''
                building of firmware for manual flashing
              '';
              enableKlipperFlash = mkEnableOption ''
                flashings scripts for firmware. This will add `klipper-flash-$mcu` scripts to your environment which can be called to flash the firmware.
                Please check the configs at [klipper](https://github.com/Klipper3d/klipper/tree/master/config) whether your board supports flashing via `make flash`
              '';
              serial = mkOption {
                type = types.nullOr path;
                description = "Path to serial port this printer is connected to. Leave `null` to derive it from `service.klipper.settings`.";
              };
              configFile = mkOption {
                type = path;
                description = "Path to firmware config which is generated using `klipper-genconf`";
              };
            };
          });
      };
    };
  };

  ##### implementation
  config = mkIf cfg.enable (mkMerge [
    {
      ### unconditional
      assertions = [
        {
          assertion = cfg.octoprintIntegration -> config.services.octoprint.enable;
          message = "Option services.klipper.octoprintIntegration requires Octoprint to be enabled on this system. Please enable services.octoprint to use it.";
        }
        {
          assertion = cfg.user != null -> cfg.group != null;
          message = "Option services.klipper.group is not set when services.klipper.user is specified.";
        }
        {
          assertion = (cfg.configFile != null) || (cfg.settings != null) || (cfg.mutableSettings != null);
          message = "You need to either specify at least one of services.klipper.configFile, services.klipper.settings, or services.klipper.mutableSettings";
        }
        {
          assertion = (cfg.apiServer.allowSystemControl -> config.security.polkit.enable);
          message = "services.klipper.apiServer.allowSystemControl requires security.polkit.enable = true";
        }
        {
          assertion = (cfg.apiServer.allowSystemControl -> cfg.user != null);
          message = "services.klipper.apiServer.allowSystemControl requires a statically allocated user. Set services.klipper.user to a username defines in users.users.";
        }
      ]
      ++ mapAttrsToList
        (mcu: fwCfg: {
          assertion = (fwCfg.enable) -> (fwCfg ? serial) || (cfg.mergedSettings ? "${mcu}".serial);
          message = ''
            Option services.klipper.settings."${mcu}".serial or services.klipper.firwmares."${mcu}".serial must be set when services.klipper.firmwares."${mcu}".enable is true
          '';
        })
        cfg.firmwares;

      warnings = (optional cfg.mutableConfig "Option services.klipper.mutableConfig is deprecated, use mutableSettings instead.");

      systemd.services.klipper =
        let
          klippyArgs = "--input-tty=${cfg.inputTTY}"
            + optionalString (cfg.apiSocket != null) " --api-server=${cfg.apiSocket}"
            + optionalString (cfg.logFile != null) " --logfile=${cfg.logFile}"
          ;
          # if mutableConfig is set generate a config directly from settings or
          # configFile. Otherwise generate a mutableConfig from mutableSettings
          # and include configFile and the a generated config file from 
          # settings.
          generateConfig = input: format.generate "klipper.cfg" (flattenConfig input);
          printerConfigFile =
            if (cfg.mutableConfig)
            then
              (
                if (cfg.configFile != null)
                then cfg.configFile
                else generateConfig cfg.settings
              )
            else
              generateConfig (
                (optionalAttrs (cfg.settings != null)
                  { "include ${cfg.immutableConfigPath}" = { }; })
                // cfg.mutableSettings
              );
          printerConfigPath = cfg.mutableConfigFolder + "/printer.cfg";
        in
        {
          description = "Klipper 3D Printer Firmware";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          preStart = ''
            mkdir -p ${cfg.mutableConfigFolder}
            [ -e ${printerConfigPath} ] || {
              cp ${printerConfigFile} ${printerConfigPath}
              chmod ug+w ${printerConfigPath}
            }
          '';

          serviceConfig = baseServiceConfig // {
            ExecStart = "${cfg.package}/bin/klippy ${klippyArgs} ${printerConfigPath}";
            RuntimeDirectory = "klipper";
            SupplementaryGroups = [ "dialout" ];
            WorkingDirectory = "${cfg.package}/lib";
            OOMScoreAdjust = "-999";
            CPUSchedulingPolicy = "rr";
            CPUSchedulingPriority = 99;
            IOSchedulingClass = "realtime";
            IOSchedulingPriority = 0;
            UMask = "0002";
          };
        };

      environment.systemPackages =
        with pkgs;
        let
          default = a: b: if a != null then a else b;
          firmwares = filterAttrs (n: v: v != null) (mapAttrs
            (mcu: { enable, enableKlipperFlash, configFile, serial }:
              if enable then
                pkgs.klipper-firmware.override
                  {
                    mcu = lib.strings.sanitizeDerivationName mcu;
                    firmwareConfig = configFile;
                  } else null)
            cfg.firmwares);
          firmwareFlasher = mapAttrsToList
            (mcu: firmware: pkgs.klipper-flash.override {
              mcu = lib.strings.sanitizeDerivationName mcu;
              klipper-firmware = firmware;
              flashDevice = default cfg.firmwares."${mcu}".serial cfg.settings."${mcu}".serial;
              firmwareConfig = cfg.firmwares."${mcu}".configFile;
            })
            (filterAttrs (mcu: firmware: cfg.firmwares."${mcu}".enableKlipperFlash) firmwares);
        in
        [ klipper-genconf ] ++ firmwareFlasher ++ attrValues firmwares;

      systemd.tmpfiles.settings.klipper = {
        "${cfg.immutableConfigPath}"."L+".argument =
          "${format.generate "klipper-immutable.cfg" (flattenConfig cfg.settings)}";
      };
    }

    (mkIf (cfg.configFile != null) {
      services.klipper.settings.include = [ cfg.configFile ];
    })

    (mkIf cfg.apiServer.enable (
      let
        apiConfig = cfg.apiServer;
        dataFolder = "/var/lib/klipper";
        moonrakerConfigFile = format.generate "moonraker.cfg" apiConfig.settings;
      in
      mkMerge [
        {
          systemd = {
            services.moonraker = {
              description = "Moonraker, an API web server for Klipper";
              wantedBy = [ "multi-user.target" ];
              wants = [ "klipper.service" ];
              after = [ "network.target" "klipper.service" ];
              path = [ pkgs.iproute2 ];
              serviceConfig = baseServiceConfig // {
                ExecStart = "${pkgs.moonraker}/bin/moonraker"
                  + " --datapath ${dataFolder}"
                  + " --configfile ${moonrakerConfigFile}";
                WorkingDirectory = "${dataFolder}";
              };
            };
          };

          services.klipper = {
            apiServer.settings = {
              server = {
                host = apiConfig.address;
                port = apiConfig.port;
                klippy_uds_address = cfg.apiSocket;
              };
              machine = {
                validate_service = false;
              };
            };

            # to make moonraker happy
            mutableConfigFolder = mkDefault "${dataFolder}/config";
          };
        }


        (mkIf apiConfig.allowSystemControl {
          security.polkit.extraConfig =
            let
              polkitAllow = { user, ... }@subject: { id, ... }@action:
                let
                  actionFilters = [ "action.id == ${id}" ]
                    ++ (mapAttrsToList
                    (name: value: ''action.lookup("${name}") == "${value}"'')
                    (removeAttrs action [ "id" ])
                  );
                in
                ''
                  polkit.addRule(function(action. subject) {
                    if (subject.user == "${user}" && ${
                      concatStringsSep " && " actionFilters
                    })
                      { return polkit.Results.YES; }
                    })
                '';
              moonrakerAllow = polkitAllow { user = cfg.user; };
            in
            concatLines [
              (moonrakerAllow { id = "org.freedesktop.login1.power-off"; })
              (moonrakerAllow { id = "org.freedesktop.login1.power-off-multiple-sessions"; })
              (moonrakerAllow { id = "org.freedesktop.login1.reboot"; })
              (moonrakerAllow { id = "org.freedesktop.login1.reboot-multiple-sessions"; })
              (moonrakerAllow { id = "org.freedesktop.systemd1.manage-units"; unit = "klipper.service"; })
              (moonrakerAllow { id = "org.freedesktop.systemd1.manage-units"; unit = "moonraker.service"; })
            ];
        })
      ]
    ))

    (mkIf cfg.octoprintIntegration {
      services.klipper = {
        user = config.services.octoprint.user;
        group = config.services.octoprint.group;
      };
    })
  ]);

  meta.maintainers = [
    maintainers.cab404
    maintainers.madnessasap
  ];
}
