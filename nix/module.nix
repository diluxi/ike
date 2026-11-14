# services.ike: the release as a hardened unit. a plain path, so that a
# configuration without flakes imports it as "${ike}/nix/module.nix"
{ config, lib, pkgs, ... }: let
	cfg = config.services.ike;

	# given after the release's own sys.config, whose keys it overrides
	sysConfig = pkgs.writeText "ike-sys.config" ''
		[
			{ike, [
				{listen, #{ip => {127, 0, 0, 1}, port => ${toString cfg.port}}}
			]}
		].
	'';
in {
	options.services.ike = {
		enable = lib.mkEnableOption "ike, an imageboard, a booru and a wiki";

		package = lib.mkOption {
			type = lib.types.package;
			default = (import ../. { inherit (pkgs.stdenv.hostPlatform) system; }).package;
			defaultText = lib.literalMD "ike, built with the nixpkgs its own `pins.json` names";
			description = ''
				The release to run. The default does not follow the system's
				nixpkgs: the toolchain, and later the metadata strippers whose
				output bytes name assets (hazard P7), change only when ike's
				pin does.
			'';
		};

		port = lib.mkOption {
			type = lib.types.port;
			default = 8970;
			description = "Loopback port Cowboy listens on, for the web server in front.";
		};
	};

	config = lib.mkIf cfg.enable {
		systemd.services.ike = {
			description = "ike";
			wantedBy = [ "multi-user.target" ];
			after = [ "network.target" ];
			environment = {
				HOME = "/var/lib/ike";
				# a crash dump holds whatever was in memory (hazard N5)
				ERL_CRASH_DUMP_BYTES = "0";
			};
			serviceConfig = {
				ExecStart = "${cfg.package}/rel/ike/bin/ike -noinput -config ${sysConfig}";
				Restart = "on-failure";
				DynamicUser = true;
				StateDirectory = "ike";
				StateDirectoryMode = "0700";
				WorkingDirectory = "/var/lib/ike";
				UMask = "0077";
				# hazard N2: nothing of the host's beyond its own state
				PrivateTmp = true;
				PrivateDevices = true;
				ProtectSystem = "strict";
				ProtectHome = true;
				ProtectProc = "invisible";
				ProtectClock = true;
				ProtectHostname = true;
				ProtectKernelLogs = true;
				ProtectKernelModules = true;
				ProtectKernelTunables = true;
				ProtectControlGroups = true;
				NoNewPrivileges = true;
				LockPersonality = true;
				RestrictNamespaces = true;
				RestrictRealtime = true;
				RestrictSUIDSGID = true;
				RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
				CapabilityBoundingSet = "";
				SystemCallArchitectures = "native";
				SystemCallFilter = [ "@system-service" "~@privileged" ];
			};
		};
	};
}
