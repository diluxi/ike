# boots the module in a vm and asks it over http: the black-box harness the
# later steps' tests (Caddy, backup and restore) grow in
{ pkgs }: pkgs.testers.runNixOSTest {
	name = "ike-module";

	nodes.machine = {
		imports = [ ./module.nix ];
		services.ike = {
			enable = true;
			package = pkgs.callPackage ./package.nix {};
			boards.b = "random";
			# an issuer nobody answers as: the vm has no provider, the
			# login suite has one
			oidc = {
				issuer = "http://127.0.0.1:9";
				redirectUri = "http://localhost/login/callback";
				clientSecretFile = pkgs.writeText "oidc-secret" "not-a-secret\n";
			};
			caddy = {
				enable = true;
				hostName = "http://localhost";
			};
			media.origin = "http://media.localhost";
		};
		# to ask the stripper's socket directly, with a fixture
		environment.systemPackages = [ pkgs.socat ];
		environment.etc."ike-test/base.png".source = ../test/ike_invariant_SUITE_data/base.png;
		environment.etc."ike-test/base.webm".source = ../test/ike_invariant_SUITE_data/base.webm;
	};

	# a file of its own: nix strips spaces from indented strings, not tabs
	testScript = builtins.readFile ./test.py;
}
