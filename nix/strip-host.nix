# ike's stripper on a machine of its own: a microvm on ike's host
# (strip-microvm.nix), or a host of its own reached over wireguard
# (deploying.md). it answers on tcp, one sandboxed instance per upload,
# to ike's address alone; the machine needs nothing else of ike's
{ config, lib, pkgs, ... }: let
	cfg = config.services.ike-strip;
in {
	options.services.ike-strip = {
		enable = lib.mkEnableOption "ike's stripper, answering over tcp";

		package = lib.mkOption {
			type = lib.types.package;
			description = "ike-strip, as ike's package builds it (`package.strip`).";
		};

		listenAddress = lib.mkOption {
			type = lib.types.str;
			example = "10.77.0.2";
			description = "The address it answers on: the host-only link's, or the wireguard one's.";
		};

		port = lib.mkOption {
			type = lib.types.port;
			default = 7070;
			description = "The port it answers on.";
		};

		allowFrom = lib.mkOption {
			type = lib.types.listOf lib.types.str;
			example = [ "10.77.0.1" ];
			description = "ike's address (or addresses): nobody else is answered.";
		};

		interface = lib.mkOption {
			type = lib.types.nullOr lib.types.str;
			default = null;
			example = "wg0";
			description = "The interface the firewall opens the port on, and only on; null for every one (a microvm has one link).";
		};

		# as ike's own services.ike.strip has them, which ike reads too
		maxBytes = lib.mkOption { type = lib.types.ints.positive; default = 20 * 1024 * 1024; };
		maxSide = lib.mkOption { type = lib.types.ints.positive; default = 16384; };
		maxPixels = lib.mkOption { type = lib.types.ints.positive; default = 50000000; };
		thumb = lib.mkOption { type = lib.types.ints.positive; default = 256; };
		maxSeconds = lib.mkOption { type = lib.types.ints.positive; default = 600; };
	};

	config = lib.mkIf cfg.enable {
		systemd.sockets.ike-strip = {
			description = "ike's stripper, over tcp";
			wantedBy = [ "sockets.target" ];
			listenStreams = [ "${cfg.listenAddress}:${toString cfg.port}" ];
			socketConfig = {
				Accept = true;
				MaxConnections = 4;
				FreeBind = true;
				# ike's address, and nobody else's, even past the firewall
				IPAddressAllow = cfg.allowFrom;
				IPAddressDeny = "any";
			};
		};

		systemd.services."ike-strip@" = import ./strip-unit.nix {
			strip = cfg.package;
			inherit (cfg) maxBytes maxSide maxPixels thumb maxSeconds;
		};

		networking.firewall = if cfg.interface == null
			then { allowedTCPPorts = [ cfg.port ]; }
			else { interfaces.${cfg.interface}.allowedTCPPorts = [ cfg.port ]; };
	};
}
