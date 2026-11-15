# ike-strip: the stripper and thumbnailer, outside ike's VM (invariant 6,
# hazard P1). The driver sees no tool but those named here; libvips and
# jpegtran are pinned with nixpkgs, and a bump that changes what they
# write changes stored hashes (hazard P7)
{ lib, stdenvNoCC, zig, makeWrapper, bash, coreutils, vips, libjpeg_turbo }:
stdenvNoCC.mkDerivation {
	pname = "ike-strip";
	version = "0.0.0";
	src = lib.fileset.toSource {
		root = ../strip;
		fileset = ../strip;
	};
	nativeBuildInputs = [ zig makeWrapper ];
	dontConfigure = true;
	buildPhase = ''
		runHook preBuild
		export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig
		zig fmt --check chunks.zig
		zig build-exe -O ReleaseSafe -mcpu baseline -fstrip -femit-bin=ike-chunks chunks.zig
		runHook postBuild
	'';
	installPhase = ''
		runHook preInstall
		install -Dm755 ike-chunks $out/libexec/ike-chunks
		install -Dm755 ike-strip $out/bin/ike-strip
		wrapProgram $out/bin/ike-strip --set PATH ${lib.makeBinPath [
			bash
			coreutils
			(lib.getBin vips)
			(lib.getBin libjpeg_turbo)
		]}:$out/libexec
		runHook postInstall
	'';
	meta.mainProgram = "ike-strip";
}
