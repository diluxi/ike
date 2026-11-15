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

## Options

```nix
{ config, ... }: {
	services.ike = {
		enable = true;
		boards = {
			b = "random";
			meta = "about ike";
		};
		caddy = {
			enable = true;
			hostName = "ike.amartia.online";
		};
		oidc = {
			issuer = "https://auth.amartia.online";
			clientId = "ike";
			redirectUri = "https://ike.amartia.online/login/callback";
			clientSecretFile = config.crypt.secrets.ike-oidc.path;
		};
		backup = {
			interval = 86400;
			keep = 7;
		};
	};
}
```

- **Boards.** Name to title. A board is created locked, and is never
  deleted by leaving it out.

- **Caddy.** `caddy.enable` adds a virtual host to fog's Caddy: rendered
  pages straight from `/var/cache/ike/pages`, everything else to Cowboy
  on the loopback port. It has no access log, on purpose (invariant 1),
  and caps request bodies at 64 KiB. Caddy's user joins the group `ike`
  to read the pages; it cannot read `/var/lib/ike`.
- **Limits.** `services.ike.limit` says how often an address and a
  board take posts without an account. With `caddy.enable` ike believes
  the loopback's `X-Forwarded-For`, which Caddy overwrites with the
  address it saw unless `trusted_proxies` is set; behind another proxy
  in front of Caddy that would have to be set, and nothing else.
  Without the module's Caddy, ike believes no such header and counts
  whoever connects.
- **User.** A static system user `ike`. State in `/var/lib/ike` (0700),
  pages in `/var/cache/ike` (0750).
- **Authelia.** A confidential client `ike` in `lemma/id.nix`:
  authorization code, PKCE with S256, scopes `openid profile groups`, the
  redirect URI above, id tokens signed with RS256. ike reads the nick
  from `preferred_username` in the id token and never asks the userinfo
  endpoint; Authelia from 4.39 on keeps that claim out of the id token
  unless the client has a claims policy listing it under `id_token`.
  Without the claim logins work, and nobody has a name to sign with.
  **`groups` is needed from `phi/mod` on:** ike asks for the scope at
  every login, and Authelia refuses a request for a scope the client is
  not granted, so without it in the client's `scopes` no one can log in.
  The claims policy must also put `groups` in the id token; without that,
  logins work and nobody has a role. `services.ike.roles` names the
  groups (default `ike-admin`, `ike-moderator`, `ike-janitor`).
  The secret, if there is one, is loaded with
  `LoadCredential` and need not be readable by ike's user; its first
  line is the secret.
- **Egress.** ike connects out to the issuer and nowhere else.

## Backups and restoring

Snapshots land in `/var/lib/ike/backups/<UTC time>.db`, whole SQLite
databases, never half-written, each a full copy. Copying them elsewhere (witness0, say) is
fog's; anything that copies files will do.

To restore:

```sh
systemctl stop ike
cd /var/lib/ike
rm -f ike.db ike.db-wal ike.db-shm
install -o ike -g ike -m 0640 backups/20261115T030000Z.db ike.db
systemctl start ike
```

ike migrates the snapshot if it is from an older version and renders
every page again. Sessions outlive a restart but not a restore, since
snapshots are taken without them; accounts do. CI does this on
every change (`ike_backup_SUITE`).

## Not there

- **A VM of its own** is not planned (decisions.md). Should that change,
  the module assumes nothing about the host: a second host directory in
  fog importing the same module is all it takes on ike's side.
- **A firewall rule for ike's egress** (N2) would be fog's.
