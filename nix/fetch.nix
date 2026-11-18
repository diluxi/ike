# ike-fetch: the fetcher, outside ike's VM (invariant 7, hazards N1, N7):
# Python's standard library and nothing else, run once per link by a
# sandboxed unit that reaches public addresses only
{ lib, stdenvNoCC, python3 }:
stdenvNoCC.mkDerivation {
	pname = "ike-fetch";
	version = "0.0.0";
	src = lib.fileset.toSource {
		root = ../fetch;
		fileset = ../fetch;
	};
	dontConfigure = true;
	dontBuild = true;
	installPhase = ''
		runHook preInstall
		install -Dm755 ike-fetch $out/bin/ike-fetch
		substituteInPlace $out/bin/ike-fetch \
			--replace-fail '#!/usr/bin/env python3' '#!${python3}/bin/python3'
		runHook postInstall
	'';
	meta.mainProgram = "ike-fetch";
}
