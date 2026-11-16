# services.ike: the release as a hardened unit, and optionally its place in
# caddy. a plain path, imported as "${ike}/nix/module.nix"
{ config, lib, pkgs, ... }: let
	cfg = config.services.ike;

	# derived from the database and rebuilt at every start, hence a cache.
	# apart from the state, so that caddy can read pages and nothing else
	pages = "/var/cache/ike/pages";
	# the files of shown posts' images: derived from the state as pages
	# are, made again at every start, and read by caddy for the media host
	media = "/var/cache/ike/media";

	# what cowboy sends with its own responses, for the pages caddy serves
	csp = "default-src 'none'; img-src ${cfg.media.origin}; form-action 'self'; base-uri 'none'; frame-ancestors 'none'";

	# the stripper's socket; a unit behind it runs once per upload
	stripSocket = "/run/ike-strip/strip.sock";
	strip = cfg.package.strip;
	# a whole upload form: every file at its cap, and room for the rest
	uploadBytes = cfg.strip.maxBytes * cfg.strip.files + 1048576;

	# given after the release's own sys.config, whose keys it overrides
	sysConfig = pkgs.writeText "ike-sys.config" ''
		[
			{ike, [
				{listen, #{ip => {127, 0, 0, 1}, port => ${toString cfg.port}}},
				{data_dir, <<"/var/lib/ike">>},
				{pages_dir, <<"${pages}">>},
				{media_dir, <<"${media}">>},
				{backup_seconds, ${toString cfg.backup.interval}},
				{backup_keep, ${toString cfg.backup.keep}},
				{boards, [${lib.concatStringsSep ", " (lib.mapAttrsToList
					(name: title: ''{<<"${name}">>, <<${builtins.toJSON title}/utf8>>}'')
					cfg.boards)}]},
				{anonymous_names, [${lib.concatMapStringsSep ", "
					(name: "<<${builtins.toJSON name}/utf8>>")
					cfg.anonymousNames}]},
				{roles, #{
					admin => <<${builtins.toJSON cfg.roles.admin}/utf8>>,
					moderator => <<${builtins.toJSON cfg.roles.moderator}/utf8>>,
					janitor => <<${builtins.toJSON cfg.roles.janitor}/utf8>>
				}},
				{hold_seconds, ${toString cfg.holdSeconds}},
				{strip, #{
					socket => <<"${stripSocket}">>,
					max_bytes => ${toString cfg.strip.maxBytes},
					max_side => ${toString cfg.strip.maxSide},
					max_pixels => ${toString cfg.strip.maxPixels},
					thumb => ${toString cfg.strip.thumb},
					files => ${toString cfg.strip.files}
				}},
				{media_origin, <<"${cfg.media.origin}">>},
				{staged_seconds, ${toString cfg.media.stagedSeconds}},
				{images, ${toString cfg.media.images}},
				{limit, #{
					posts => ${toString cfg.limit.posts},
					seconds => ${toString cfg.limit.seconds},
					board_posts => ${toString cfg.limit.boardPosts},
					board_seconds => ${toString cfg.limit.boardSeconds},
					salt_seconds => ${toString cfg.limit.saltSeconds},
					v6_prefix => ${toString cfg.limit.v6Prefix},
					proxies => [${lib.optionalString cfg.caddy.enable
						"{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}"}]
				}}${lib.optionalString (cfg.oidc != null) '',
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

		limit = {
			posts = lib.mkOption {
				type = lib.types.ints.positive;
				default = 4;
				description = ''
					How many posts one address may send in `seconds` without
					an account behind them. An IPv6 address counts as its
					whole network of `v6Prefix` bits. Counted in memory, under
					a key that is thrown away every `saltSeconds`, and never
					written anywhere.
				'';
			};
			seconds = lib.mkOption {
				type = lib.types.ints.positive;
				default = 60;
				description = "The stretch of time `posts` is counted over.";
			};
			boardPosts = lib.mkOption {
				type = lib.types.ints.positive;
				default = 10;
				description = ''
					How many posts without an account one board takes in
					`boardSeconds`, from all addresses together: what still
					holds against someone with many addresses.
				'';
			};
			boardSeconds = lib.mkOption {
				type = lib.types.ints.positive;
				default = 60;
				description = "The stretch of time `boardPosts` is counted over.";
			};
			saltSeconds = lib.mkOption {
				type = lib.types.ints.positive;
				default = 3600;
				description = ''
					How long the key lives that addresses are hashed with
					before they are counted. With a new key every count by
					address starts over.
				'';
			};
			v6Prefix = lib.mkOption {
				type = lib.types.enum [ 48 56 64 ];
				default = 64;
				description = ''
					The size of the IPv6 network counted as one address. 64
					is one subscriber at most providers; some hand out a 56
					or a 48 to each.
				'';
			};
		};
		roles = {
			admin = lib.mkOption {
				type = lib.types.str;
				default = "ike-admin";
				description = "The provider's group whose accounts are admins: every action, purge included.";
			};
			moderator = lib.mkOption {
				type = lib.types.str;
				default = "ike-moderator";
				description = "The group whose accounts moderate: everything but purge.";
			};
			janitor = lib.mkOption {
				type = lib.types.str;
				default = "ike-janitor-";
				description = "The prefix of the groups whose accounts may hide and unhide posts on one board: `ike-janitor-b` for /b/.";
			};
		};

		holdSeconds = lib.mkOption {
			type = lib.types.ints.positive;
			default = 14 * 86400;
			description = ''
				How long a deleted post is kept, out of sight, before ike
				purges it. An open decision in planning.md; this is a stub.
			'';
		};

		media = {
			origin = lib.mkOption {
				type = lib.types.str;
				example = "https://cdn.example.org";
				description = ''
					Where uploads are served from: an origin other than ike's
					own, ideally a registered domain of its own (hazard P3).
					Pages name it, so changing it is a restart, which renders
					them all again.
				'';
			};
			images = lib.mkOption {
				type = lib.types.ints.positive;
				default = 8;
				description = "Most images one post shows. A stub: the caps are open in planning.md.";
			};
			stagedSeconds = lib.mkOption {
				type = lib.types.ints.positive;
				default = 600;
				description = "How long a link to a staged upload works, from when its uploader's page was made.";
			};
		};

		strip = {
			maxBytes = lib.mkOption {
				type = lib.types.ints.positive;
				default = 20 * 1024 * 1024;
				description = "Largest upload taken, in bytes. A stub: the caps are open in planning.md.";
			};
			maxSide = lib.mkOption {
				type = lib.types.ints.positive;
				default = 16384;
				description = "Longest side taken, in pixels, read from the header before decoding (hazard P2).";
			};
			maxPixels = lib.mkOption {
				type = lib.types.ints.positive;
				default = 50000000;
				description = "Most pixels taken, width times height, read from the header.";
			};
			thumb = lib.mkOption {
				type = lib.types.ints.positive;
				default = 256;
				description = "Longest side of a thumbnail, in pixels.";
			};
			files = lib.mkOption {
				type = lib.types.ints.positive;
				default = 20;
				description = "Most files in one upload form.";
			};
		};

		caddy = {
			enable = lib.mkEnableOption ''
				a Caddy virtual host for ike: the rendered pages straight from
				disk, everything else passed on to Cowboy; and one for the
				media origin
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
			# the media origin: staged uploads through ike, and the files of
			# shown posts from disk. no cookie is ever set here, and nothing
			# it serves may run
			virtualHosts.${cfg.media.origin} = {
				logFormat = null;
				extraConfig = ''
					header {
						Content-Security-Policy "default-src 'none'; sandbox"
						X-Content-Type-Options nosniff
						Referrer-Policy no-referrer
					}
					request_body {
						max_size 1KB
					}
					handle /staged/* {
						reverse_proxy 127.0.0.1:${toString cfg.port}
					}
					@file path_regexp ^/[0-9a-f]{64}\.(jpg|png|webp|thumb\.webp)$
					handle @file {
						root * ${media}
						file_server
					}
					handle {
						respond 404
					}
				'';
			};
			virtualHosts.${cfg.caddy.hostName} = {
				# invariant 1: an access log is a list of addresses
				logFormat = null;
				extraConfig = ''
					header {
						Content-Security-Policy "${csp}"
						X-Content-Type-Options nosniff
						Referrer-Policy same-origin
					}
					@upload path /upload
					request_body @upload {
						max_size ${toString uploadBytes}
					}
					@form not path /upload
					request_body @form {
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

		# hazard P1: every upload is stripped by a process of its own, one
		# per connection, that can reach nothing and change nothing but
		# its scratch directory, within limits; ike only holds the socket
		systemd.sockets.ike-strip = {
			description = "ike's stripper";
			wantedBy = [ "sockets.target" ];
			listenStreams = [ stripSocket ];
			socketConfig = {
				Accept = true;
				SocketUser = "root";
				SocketGroup = "ike";
				SocketMode = "0660";
				MaxConnections = 4;
			};
		};

		systemd.services."ike-strip@" = {
			description = "ike's stripper, for one upload";
			serviceConfig = {
				ExecStart = "${strip}/bin/ike-strip ${toString cfg.strip.maxBytes} ${toString cfg.strip.maxSide} ${toString cfg.strip.maxPixels} ${toString cfg.strip.thumb}";
				StandardInput = "socket";
				StandardOutput = "socket";
				StandardError = "journal";
				DynamicUser = true;
				PrivateNetwork = true;
				IPAddressDeny = "any";
				RestrictAddressFamilies = "none";
				PrivateTmp = true;
				PrivateDevices = true;
				PrivateUsers = true;
				ProtectSystem = "strict";
				ProtectHome = true;
				ProtectProc = "invisible";
				ProcSubset = "pid";
				ProtectClock = true;
				ProtectHostname = true;
				ProtectKernelLogs = true;
				ProtectKernelModules = true;
				ProtectKernelTunables = true;
				ProtectControlGroups = true;
				NoNewPrivileges = true;
				LockPersonality = true;
				MemoryDenyWriteExecute = true;
				RestrictNamespaces = true;
				RestrictRealtime = true;
				RestrictSUIDSGID = true;
				CapabilityBoundingSet = "";
				SystemCallArchitectures = "native";
				SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
				UMask = "0077";
				MemoryMax = "1G";
				CPUQuota = "100%";
				TasksMax = 32;
				RuntimeMaxSec = 60;
			};
		};

		systemd.services.ike = {
			description = "ike";
			wantedBy = [ "multi-user.target" ];
			after = [ "network.target" "ike-strip.socket" ];
			wants = [ "ike-strip.socket" ];
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
