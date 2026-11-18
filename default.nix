# the entry for everything: `nix-build -A package`, `nix-build -A checks`,
# `nix-shell`. no flake, as in fog
{
	system ? builtins.currentSystem,
	pkgs ? import pins.nixpkgs { inherit system; },
	pins ? builtins.mapAttrs (_: { url, sha256 }: fetchTarball {
		inherit url sha256;
		name = "source";
	}) (builtins.fromJSON (builtins.readFile ./pins.json)),
}: let
	package = pkgs.callPackage ./nix/package.nix {};
in {
	inherit package;

	checks = {
		inherit package;
		inherit (package) tests;
	} // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
		module = import ./nix/test.nix { inherit pkgs; };
		# the stripper on a host of its own, over tcp
		remote-strip = import ./nix/test-remote.nix { inherit pkgs; };
		# the microvm: built, not booted (no kvm inside a test's vm)
		microvm = (pkgs.nixos {
			imports = [
				./nix/module.nix
				./nix/strip-microvm.nix
				"${pins.microvm}/nixos-modules/host"
			];
			boot.loader.grub.enable = false;
			fileSystems."/".device = "/dev/null";
			system.stateVersion = "25.05";
			services.ike = {
				enable = true;
				package = package;
				boards.b = "random";
				media.origin = "http://media.localhost";
				oidc = {
					issuer = "http://127.0.0.1:9";
					redirectUri = "http://localhost/login/callback";
				};
				strip.isolation = "microvm";
			};
		}).config.microvm.vms.ike-strip.config.config.microvm.declaredRunner;
	} // pkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
		inherit (package) types;
	};

	shell = pkgs.mkShell {
		packages = [
			package.beamPackages.erlang
			package.beamPackages.rebar3
			package.beamPackages.erlfmt
			package.elp
			package.strip
			package.fetch
			pkgs.exiftool
			pkgs.ffmpeg-headless
			pkgs.sqlite
		];
	};

	module = ./nix/module.nix;
	# the stripper on a machine of its own: a host (deploying.md) or, with
	# microvm.nix's host module, a microvm on ike's host
	stripHost = ./nix/strip-host.nix;
	stripMicrovm = ./nix/strip-microvm.nix;
}
