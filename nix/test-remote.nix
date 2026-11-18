# the stripper on a host of its own (lux, 2026-11-18: option 2, and the
# microvm's way too): ike on one machine, strip-host.nix on another, the
# stripper answering over tcp to ike's address and nobody else's
{ pkgs }: pkgs.testers.runNixOSTest {
	name = "ike-remote-strip";

	nodes.ike = { nodes, ... }: {
		imports = [ ./module.nix ];
		services.ike = {
			enable = true;
			package = pkgs.callPackage ./package.nix {};
			boards.b = "random";
			oidc = {
				issuer = "http://127.0.0.1:9";
				redirectUri = "http://localhost/login/callback";
				clientSecretFile = pkgs.writeText "oidc-secret" "not-a-secret\n";
			};
			media.origin = "http://media.localhost";
			strip = {
				isolation = "remote";
				address = nodes.stripper.networking.primaryIPAddress;
			};
		};
		environment.systemPackages = [ pkgs.socat ];
		environment.etc."ike-test/base.png".source = ../test/ike_invariant_SUITE_data/base.png;
	};

	nodes.stripper = { nodes, ... }: {
		imports = [ ./strip-host.nix ];
		services.ike-strip = {
			enable = true;
			package = (pkgs.callPackage ./package.nix {}).strip;
			listenAddress = nodes.stripper.networking.primaryIPAddress;
			allowFrom = [ nodes.ike.networking.primaryIPAddress ];
			interface = "eth1";
		};
		environment.systemPackages = [ pkgs.socat ];
		environment.etc."ike-test/base.png".source = ../test/ike_invariant_SUITE_data/base.png;
	};

	testScript = builtins.readFile ./test-remote.py;
}
