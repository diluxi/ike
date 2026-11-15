# services.ike: the release as a hardened unit, and optionally its place in
# caddy. a plain path, imported as "${ike}/nix/module.nix"
{ config, lib, pkgs, ... }: let
	cfg = config.services.ike;

	# derived from the database and rebuilt at every start, hence a cache.
	# apart from the state, so that caddy can read pages and nothing else
	pages = "/var/cache/ike/pages";

	# what cowboy sends with its own responses, for the pages caddy serves
	csp = "default-src 'none'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'";

	# given after the release's own sys.config, whose keys it overrides
	sysConfig = pkgs.writeText "ike-sys.config" ''
		[
			{ike, [
				{listen, #{ip => {127, 0, 0, 1}, port => ${toString cfg.port}}},
				{data_dir, <<"/var/lib/ike">>},
				{pages_dir, <<"${pages}">>},
				{backup_seconds, ${toString cfg.backup.interval}},
				{backup_keep, ${toString cfg.backup.keep}},
				{boards, [${lib.concatStringsSep ", " (lib.mapAttrsToList
					(name: title: ''{<<"${name}">>, <<${builtins.toJSON title}/utf8>>}'')
					cfg.boards)}]},
				{anonymous_names, [${lib.concatMapStringsSep ", "
					(name: "<<${builtins.toJSON name}/utf8>>")
					cfg.anonymousNames}]}${lib.optionalString (cfg.oidc != null) '',
				{oidc, #{
					issuer => <<"${cfg.oidc.issuer}">>,
					client_id => <<"${cfg.oidc.clientId}">>,
					redirect_uri => <<"${cfg.oidc.redirectUri}">>${
						lib.optionalString (cfg.oidc.clientSecretFile != null) '',
					client_secret_file => <<"/run/credentials/ike.service/oidc-secret">>''
					}
				}}''}
			]}
		].
	'';
in {
	options.services.ike = {
		enable = lib.mkEnableOption "ike, an imageboard, a booru and a wiki";

		boards = lib.mkOption {
			type = lib.types.attrsOf lib.types.str;
			default = {};
			example = { b = "random"; };
			description = ''
				The boards there are, as name and title. A name is one to
				sixteen of a to z and digits. Taking a board out of here
				does not delete it or its threads.
			'';
		};

		anonymousNames = lib.mkOption {
			type = lib.types.nonEmptyListOf lib.types.str;
			default = [ "anon" ];
			example = [ "nemo" "outis" "nihil" ];
			description = ''
				What stands where a name would on a post that carries none.
				Given several, each post takes one of them by its number,
				and keeps it for as long as the list does not change.
			'';
		};

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

		oidc = lib.mkOption {
			default = null;
			description = ''
				The OpenID provider accounts log in through. Without one ike
				runs, and nobody can log in.
			'';
			type = lib.types.nullOr (lib.types.submodule {
				options = {
					issuer = lib.mkOption {
						type = lib.types.str;
						example = "https://id.example.org";
						description = ''
							The issuer, exactly as its discovery document names
							it: no trailing slash unless it has one there.
						'';
					};
					clientId = lib.mkOption {
						type = lib.types.str;
						default = "ike";
						description = "The client the provider knows ike as.";
					};
					redirectUri = lib.mkOption {
						type = lib.types.str;
						example = "https://ike.example.org/login/callback";
						description = ''
							Where the provider sends the browser back to: ike's
							public address, then `/login/callback`.
						'';
					};
					clientSecretFile = lib.mkOption {
						type = lib.types.nullOr lib.types.path;
						default = null;
						description = ''
							A file holding the client secret, for a confidential
							client; its first line is the secret. Loaded as a
							credential, so it need not be readable by ike's
							user. A public client, which PKCE alone protects,
							has none.
						'';
					};
				};
			});
		};

		backup = {
			interval = lib.mkOption {
				type = lib.types.ints.positive;
				default = 86400;
				description = ''
					Seconds between snapshots of the database, which land in
					`/var/lib/ike/backups`, named for when they were taken.
					Taking them off the host is the host's affair.
				'';
			};

			keep = lib.mkOption {
				type = lib.types.ints.positive;
				default = 7;
				description = ''
					How many snapshots are kept; older ones are deleted. What
					was purged from ike lives on in them for `interval` times
					`keep`, and for as long as copies made elsewhere are kept
					(hazard D7).
				'';
			};
		};

		caddy = {
			enable = lib.mkEnableOption ''
				a Caddy virtual host for ike: the rendered pages straight from
				disk, everything else passed on to Cowboy
			'';

			hostName = lib.mkOption {
				type = lib.types.str;
				example = "ike.example.org";
				description = "The site address, as Caddy takes it.";
			};
		};
	};

	config = lib.mkIf cfg.enable {
		# a user of its own and not DynamicUser, whose directories nobody
		# else can reach: caddy has to read the pages
		users.users.ike = {
			isSystemUser = true;
			group = "ike";
		};
		users.groups.ike = {};
		users.users.caddy = lib.mkIf cfg.caddy.enable { extraGroups = [ "ike" ]; };

		services.caddy = lib.mkIf cfg.caddy.enable {
			enable = true;
			virtualHosts.${cfg.caddy.hostName} = {
				# invariant 1: an access log is a list of addresses
				logFormat = null;
				extraConfig = ''
					header {
						Content-Security-Policy "${csp}"
						X-Content-Type-Options nosniff
						Referrer-Policy same-origin
					}
					request_body {
						max_size 64KB
					}
					@page {
						method GET HEAD
						file {
							root ${pages}
							try_files {path}.html {path}index.html
						}
					}
					handle @page {
						root * ${pages}
						rewrite * {file_match.relative}
						file_server
					}
					handle {
						reverse_proxy 127.0.0.1:${toString cfg.port}
					}
				'';
			};
		};

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
				LoadCredential = lib.optional
					(cfg.oidc != null && cfg.oidc.clientSecretFile != null)
					"oidc-secret:${cfg.oidc.clientSecretFile}";
				User = "ike";
				Group = "ike";
				StateDirectory = "ike";
				StateDirectoryMode = "0700";
				CacheDirectory = "ike";
				CacheDirectoryMode = "0750";
				WorkingDirectory = "/var/lib/ike";
				# pages are group-readable; the state directory's own mode
				# keeps everyone out of the database
				UMask = "0027";
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
