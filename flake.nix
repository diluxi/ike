{
	description = "ike: an imageboard, a booru and a wiki over one store";

	# no inputs and so no flake.lock: default.nix is the entry and takes its
	# pins from pins.json. this only gives its parts their flake names
	outputs = { self }: let
		systems = [ "x86_64-linux" "aarch64-linux" ];
		each = f: builtins.listToAttrs (map (system: {
			name = system;
			value = f (import ./. { inherit system; });
		}) systems);
	in {
		packages = each (ike: { default = ike.package; });
		checks = each (ike: ike.checks);
		devShells = each (ike: { default = ike.shell; });
		nixosModules.default = ./nix/module.nix;
	};
}
