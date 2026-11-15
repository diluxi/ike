{ lib, stdenv, beam, runCommand, zlib, erlang-language-platform, callPackage, exiftool }: let
	beamPackages = beam.packages.erlang_29;

	# what rebar.lock names, fetched by hash; `nix/lock` writes the list
	hex = builtins.fromJSON (builtins.readFile ./hex.json);
	# rebar3 builds whatever sits in _checkouts without asking hex.pm
	checkouts = runCommand "ike-checkouts" {} (''
		mkdir -p $out/_checkouts
	'' + lib.concatMapStrings (dep: ''
		cp -r ${beamPackages.fetchHex { inherit (dep) pkg version sha256; }} \
			$out/_checkouts/${dep.name}
	'') hex);

	elp = erlang-language-platform.override { inherit beamPackages; };
	strip = callPackage ./strip.nix {};
	# elp carries eqwalizer as a native image, unpacks it into $TMPDIR and
	# runs it there. the image asks for /lib64's loader, which a nix sandbox
	# doesn't have and patchelf can't fix inside another binary. so the
	# loader's path is overwritten in place with one short enough to fit,
	# which the check then provides
	loader = "/build/ld.so";
	elpSandboxed = runCommand "elp-sandboxed" {} ''
		mkdir -p $out/bin
		from=/lib64/ld-linux-x86-64.so.2
		[ "$(grep -c -a "$from" ${elp}/bin/elp)" = 1 ]
		pad=$(printf '\\x00%.0s' $(seq $((''${#from} - ${toString (builtins.stringLength loader)}))))
		LC_ALL=C sed "s|$from|${loader}$pad|" ${elp}/bin/elp >$out/bin/elp
		chmod +x $out/bin/elp
	'';

	src = lib.fileset.toSource {
		root = ../.;
		fileset = lib.fileset.unions [
			../.elp.toml
			../rebar.config
			../rebar.lock
			../config
			../priv
			../src
			../test
		];
	};

	ike = beamPackages.rebar3Relx {
		pname = "ike";
		version = "0.0.0";
		inherit src checkouts;
		releaseType = "release";
		profile = "prod";
		# esqlite builds its nif, and the sqlite it carries, with pc
		buildPlugins = [ beamPackages.pc ];

		passthru = {
			inherit beamPackages checkouts elp strip;
			# the release's tests, against the same sources and dependencies
			tests = ike.overrideAttrs (old: {
				pname = "ike-tests";
				# invariant 11 runs the stripper, and exiftool reads what it left
				nativeBuildInputs = old.nativeBuildInputs ++ [ beamPackages.erlfmt strip exiftool ];
				buildPhase = ''
					runHook preBuild
					erlfmt --check rebar.config config/*.config src/* test/*.erl
					HOME=. rebar3 do xref, ct
					runHook postBuild
				'';
				installPhase = "touch $out";
			});
			# eqwalizer, over every module under src; the tests stay untyped
			types = ike.overrideAttrs (old: {
				pname = "ike-types";
				nativeBuildInputs = old.nativeBuildInputs ++ [ elpSandboxed ];
				buildPhase = ''
					runHook preBuild
					ln -s ${stdenv.cc.libc}/lib/ld-linux-x86-64.so.2 ${loader}
					export LD_LIBRARY_PATH=${lib.makeLibraryPath [ zlib ]}
					HOME=$PWD elp eqwalize --color never --bail-on-error \
						$(basename -s .erl src/*.erl)
					runHook postBuild
				'';
				installPhase = "touch $out";
			});
		};

		meta = {
			description = "Imageboard, booru and wiki over one store";
			mainProgram = "ike";
		};
	};
in ike
