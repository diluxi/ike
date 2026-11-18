# ike's stripper in a microvm on ike's host (lux, 2026-11-18: option 1,
# until a host of its own, option 2, deploying.md): a kernel of its own
# between an upload and ike. cloud-hypervisor, the host's /nix/store read
# only over virtiofs, no disk, and one link: a tap on a host-only /30,
# no route anywhere. ike reaches it at its address over tcp
# (services.ike.strip.isolation = "microvm").
#
# needs microvm.nix's host module (astro/microvm.nix, nixos-modules/host)
# imported beside this one; ike pins the version it is tested with in
# pins.json. the host needs kvm: a dedicated machine, not a cloud vm
# without nested virtualisation
{ config, lib, pkgs, ... }: let
	cfg = config.services.ike;
	vm = cfg.strip.microvm;
in {
	options.services.ike.strip.microvm = {
		hostAddress = lib.mkOption {
			type = lib.types.str;
			default = "10.77.0.1";
			description = "The host's end of the link.";
		};
		guestAddress = lib.mkOption {
			type = lib.types.str;
			default = "10.77.0.2";
			description = "The microvm's end, where the stripper answers.";
		};
		vcpu = lib.mkOption { type = lib.types.ints.positive; default = 2; };
		mem = lib.mkOption {
			type = lib.types.ints.positive;
			default = 1536;
			description = "MiB; a stripper instance may take 1 GiB.";
		};
	};

	config = lib.mkIf (cfg.enable && cfg.strip.isolation == "microvm") {
		services.ike.strip.address = vm.guestAddress;

		microvm.host.enable = true;
		microvm.vms.ike-strip = {
			autostart = true;
			config = {
				imports = [ ./strip-host.nix ];
				system.stateVersion = config.system.stateVersion;
				networking.hostName = "ike-strip";
				microvm = {
					hypervisor = "cloud-hypervisor";
					inherit (vm) vcpu mem;
					interfaces = [{
						type = "tap";
						id = "vm-ike-strip";
						mac = "02:00:00:77:00:02";
					}];
					shares = [{
						proto = "virtiofs";
						tag = "ro-store";
						source = "/nix/store";
						mountPoint = "/nix/.ro-store";
					}];
				};
				networking.useDHCP = false;
				systemd.network = {
					enable = true;
					networks."10-link" = {
						matchConfig.MACAddress = "02:00:00:77:00:02";
						address = [ "${vm.guestAddress}/30" ];
					};
				};
				services.ike-strip = {
					enable = true;
					package = cfg.package.strip;
					listenAddress = vm.guestAddress;
					inherit (cfg.strip) port maxBytes maxSide maxPixels thumb maxSeconds;
					allowFrom = [ vm.hostAddress ];
				};
			};
		};

		# the host's end: an address on the tap, and nothing forwarded
		systemd.network = {
			enable = true;
			networks."10-ike-strip" = {
				matchConfig.Name = "vm-ike-strip";
				address = [ "${vm.hostAddress}/30" ];
				networkConfig.IPv4Forwarding = false;
			};
		};
	};
}
