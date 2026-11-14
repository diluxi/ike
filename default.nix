# the entry for everything, flakes or not: `nix-build -A package`,
# `nix-build -A checks`, `nix-shell`. flake.nix only wraps this
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
	} // pkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
		inherit (package) types;
	};

	shell = pkgs.mkShell {
		packages = [
			package.beamPackages.erlang
			package.beamPackages.rebar3
			package.beamPackages.erlfmt
			package.elp
			pkgs.sqlite
		];
	};

	module = ./nix/module.nix;
}
