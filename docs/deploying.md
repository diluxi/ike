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
		caddy = {
			enable = true;
			hostName = "ike.amartia.online";
		};
		oidc = {
			issuer = "https://id.amartia.online";
			clientId = "ike";
			redirectUri = "https://ike.amartia.online/login/callback";
			# only for a confidential client
			clientSecretFile = config.crypt.secrets.ike-oidc.path;
		};
		backup = {
			interval = 86400;
			keep = 7;
		};
	};
}
```

The names above are examples; which host name and which kind of client
are open (questions.md, Q7).

- **Caddy.** `caddy.enable` adds a virtual host to fog's Caddy: rendered
  pages straight from `/var/cache/ike/pages`, everything else to Cowboy
  on the loopback port. It has no access log, on purpose (invariant 1),
  and caps request bodies at 64 KiB. Caddy's user joins the group `ike`
  to read the pages; it cannot read `/var/lib/ike`.
- **User.** A static system user `ike`. State in `/var/lib/ike` (0700),
  pages in `/var/cache/ike` (0750).
- **Authelia.** A client for ike in `lemma/id.nix`: authorization code,
  PKCE with S256, scope `openid`, the redirect URI above, id tokens
  signed with RS256. The secret, if there is one, is loaded with
  `LoadCredential` and need not be readable by ike's user; its first
  line is the secret.
- **Egress.** ike connects out to the issuer and nowhere else.

## Backups and restoring

Snapshots land in `/var/lib/ike/backups/<UTC time>.db`, whole SQLite
databases, never half-written. Copying them elsewhere (witness0, say) is
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
every page again. Sessions do not survive; accounts do. CI does this on
every change (`ike_backup_SUITE`).

## Not there

- **A VM of its own** is not planned (decisions.md). Should that change,
  the module assumes nothing about the host: a second host directory in
  fog importing the same module is all it takes on ike's side.
- **A firewall rule for ike's egress** (N2) would be fog's.
