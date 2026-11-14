# ike — deploying from fog

How a NixOS configuration without flakes takes ike in. Written against fog
as of 2026-11-14 (`default.nix` evaluating `pins.json`); nothing here has
been applied to fog.

## Pin

fog already pins tarballs by revision and hash, so ike is one more:

```sh
./fog pin ike diluxi/ike dev
```

That needs the repository to be public, since `fog pin` and `fetchTarball`
fetch GitHub's archive without credentials.

## Import

`nix/module.nix` is a plain module path, like disko's. In fog's
`default.nix`:

```nix
modules = [
	"${pins.disko}/module.nix"
	"${pins.ike}/nix/module.nix"
	./crypt.nix
	./users
	./lemma
];
```

and a `lemma/ike.nix`, imported from `lemma/default.nix`:

```nix
{ ... }: {
	services.ike.enable = true;
}
```

No flake is evaluated anywhere: the module imports ike's `default.nix`,
which reads ike's `pins.json` and fetches the nixpkgs it names
with `fetchTarball`.

## Which nixpkgs builds it

By default ike is built with the nixpkgs in its own `pins.json`, not
fog's, so that what runs is what ike's CI tested (decisions.md). While both
pin the same revision, as now, there is nothing extra to fetch or build.
To build with fog's nixpkgs instead:

```nix
{ pkgs, ... }: {
	services.ike.package = pkgs.callPackage "${pins.ike}/nix/package.nix" {};
}
```

(`pins` would have to reach the module, through `specialArgs` in
`default.nix`.)

## Updating

A new ike reaches lemma0 only as a commit in fog that changes `pins.json`:
`./fog pin ike diluxi/ike dev` again, evaluate, commit, push. fog-deploy
tests a phi-signed tip and lux ratifies, as with any other change. ike's
own signatures are not checked by fog-deploy; the pinned hash is what binds
fog to an exact tree, so the pin bump is the commit to review.

## What M0 will add here

Not there yet; listed so fog's side can be planned.

- **The web server** (questions.md, C1). ike's module will offer an nginx
  virtual host as a separate option, off by default. On lemma0, Caddy owns
  80 and 443: either Caddy serves ike's page directory and proxies the
  rest, or nginx listens on loopback behind it.
- **State.** `/var/lib/ike` (database, media, pages), through
  `StateDirectory` with `DynamicUser`. The server in front needs read
  access to the pages and media directories, which will mean a static user
  or a shared group in place of `DynamicUser`.
- **Secrets.** Paths passed as options and loaded with `LoadCredential`,
  so they fit `crypt.generated` (a session key) and `crypt.secrets` alike.
  With PKCE and a public client there is no OIDC client secret.
- **Authelia.** An OIDC client for ike in `lemma/id.nix`: authorization
  code, PKCE with S256, the redirect URI under ike's host, the `groups`
  scope for roles.
- **Backups.** A timer writing snapshots under the state directory; where
  they go from there (witness0, say) is fog's, behind one option.
- **A VM of its own** is not planned (decisions.md). Should that change,
  the module assumes nothing about the host: a second host directory in
  fog importing the same module is all it takes on ike's side.
