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
  to read the pages; it cannot read `/var/lib/ike`. The group is also
  named in Caddy's unit, so that the switch which adds it restarts Caddy:
  a reload keeps the groups it started with, and then every media file
  answers 403 while pages still work (ike serves what Caddy cannot read).
  If that is seen anyway, `systemctl restart caddy`.
- **Limits.** `services.ike.limit` says how often an address and a
  board take posts without an account. With `caddy.enable` ike believes
  the loopback's `X-Forwarded-For`, which Caddy overwrites with the
  address it saw unless `trusted_proxies` is set; behind another proxy
  in front of Caddy that would have to be set, and nothing else.
  Without the module's Caddy, ike believes no such header and counts
  whoever connects.
- **Media.** `services.ike.media.origin` is where uploads are served
  from; with `caddy.enable` the module gives it a site of its own that
  passes only signed links to staged uploads to ike. It needs DNS like
  the main host. Changing it is a restart; pages are made again then.
  For now `https://cdn.amartia.online`, accepted while ike is not public;
  it belongs on a registered domain of its own (decisions.md). Fonts
  are served with `Access-Control-Allow-Origin: *` and their font/*
  types (the module's Caddy sets both); a web server of fog's own in
  front of the media directory must do the same, or pages cannot load
  them.
- **Fonts in the stripper.** ike-strip now runs OTS and fontTools
  (Python) and draws a font's thumbnail with libvips' text, so its unit
  needs no more than it had: a writable temporary directory, which
  mktemp already uses for fontconfig's cache.
- **Stripper.** One sandboxed instance per upload (`ike-strip@.service`,
  `nix/strip-unit.nix`): no network, a dynamic user, no privileges, 1 GB
  of memory, a minute. Where it runs is `services.ike.strip.isolation`
  (below, "Where the stripper runs"). `services.ike.strip` holds the
  caps, stubs for planning's open item. Caddy lets `/upload` bodies
  through up to every file at its cap, and everything else at 64 KB.
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
  groups (default `ike-admin`, `ike-moderator`, and `ike-janitor-`
  followed by a board's name, one group per board a janitor keeps).
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

## The fetcher

`services.ike.fetch.enable = true;` lets accounts upload from a link (a
tweet, for now). A socket unit `ike-fetch.socket` at
`/run/ike-fetch/fetch.sock` (group `ike`), and `ike-fetch@.service`, one
sandboxed instance per link, allowed out to public addresses and denied
loopback, private, link-local, CGNAT, ULA and reserved ranges by systemd
(and by its own checks). Names are resolved through nscd (NixOS's
default); without nscd and with a local resolver, give its address in
`services.ike.fetch.resolvers`. It reaches x.com's hosts over https:
fog's egress rules, if any, must let it.

To check it on a host, by hand: `test/live/x-tweet.sh` (in `nix-shell`).

## Themes

No stylesheet is static (lux, 2026-11-19): ike comes with three themes
(`plain`, the site's at first; `cream`; `navy`), seeded from
`priv/themes` the first time it starts, and from then on they are rows
any moderator edits at `/mod/themes`. Each is written to the media
directory as `theme.NAME.css`, and the site's also as `style.css`; Caddy
serves those from the media host with `Cache-Control: no-cache`, and the
pages' policy is `style-src` the media origin (no stylesheet comes from
the main origin, invariant 5). Nothing to set. The rows are the truth:
the files are made again at every start.

## Where the stripper runs

Every upload is decoded by the stripper, and nothing else of ike's ever
decodes one (invariant 6, hazard P1). Three places for it, one option
apart: `services.ike.strip.isolation`. ike speaks the same to all three
(the upload in, an answer out, over one connection); only the address
differs.

### `sandbox`: a unit on ike's host (the default)

A socket unit `ike-strip.socket` at `/run/ike-strip/strip.sock`, owned
by the group `ike`. Nothing to set.

### `microvm`: a microvm on ike's host (now, lux 2026-11-18)

A kernel of its own between an upload and ike. cloud-hypervisor, no disk,
the host's `/nix/store` read only over virtiofs, and one link: a tap,
`vm-ike-strip`, on a host-only /30 (`10.77.0.1` the host, `10.77.0.2`
the microvm), with no route anywhere and nothing forwarded. The stripper
answers on `10.77.0.2:7070`, to `10.77.0.1` alone (the socket's own IP
list and the guest's firewall). 2 vCPUs and 1.5 GiB by default
(`services.ike.strip.microvm.vcpu`, `.mem`).

Needs KVM on the host: a dedicated machine, or a cloud VM with nested
virtualisation (Hetzner Cloud's is not to be relied on).

1. Pin microvm.nix in fog, the version ike tests with (`pins.json` in
   ike: `astro/microvm.nix` at the `microvm` entry):

   ```sh
   ./fog pin microvm astro/microvm.nix 194a254693f49af939a2b53d04982bd4b276fdb3
   ```

2. Import its host module and ike's microvm module beside ike's:

   ```nix
   modules = [
   	"${pins.ike}/nix/module.nix"
   	"${pins.ike}/nix/strip-microvm.nix"
   	"${pins.microvm}/nixos-modules/host"
   	# ...
   ];
   ```

3. In `lemma/ike.nix`:

   ```nix
   services.ike.strip.isolation = "microvm";
   ```

   (`strip.address` is the microvm's, set by the module.)

4. `systemd-networkd` must be on for the tap's address (the module turns
   it on; with fog's own networking set up some other way, give
   `vm-ike-strip` the address `10.77.0.1/30` there instead), and the
   /30 must not collide with any of fog's networks; change
   `services.ike.strip.microvm.hostAddress` and `.guestAddress` if it
   does.

5. Switch. `microvm@ike-strip.service` starts the microvm; ike waits for
   nothing (an upload while it boots is "not kept, try again"). Check:

   ```sh
   systemctl status microvm@ike-strip
   ss -tn dst 10.77.0.2:7070   # while an upload is stripped
   ```

### `remote`: a host of its own (next month, lux 2026-11-18)

The stripper on another machine: a Hetzner Cloud server (the smallest
shared-vCPU one does), reached over WireGuard. A kernel and a machine of
its own, and its own address to the world: what will also suit the
fetcher (Q47), whose hazard is the requests it makes.

On the new host, `strip` (a host directory in fog, as lemma is):

1. NixOS, fog's base (users, ssh), and nothing of ike's but this:

   ```nix
   { pins, ... }: let
   	ike = import pins.ike {};
   in {
   	imports = [ "${pins.ike}/nix/strip-host.nix" ];
   	networking.wireguard.interfaces.wg-ike = {
   		ips = [ "10.78.0.2/30" ];
   		listenPort = 51820;
   		privateKeyFile = "/var/lib/wireguard/wg-ike.key";
   		peers = [{
   			publicKey = "<lemma's wg-ike public key>";
   			allowedIPs = [ "10.78.0.1/32" ];
   		}];
   	};
   	networking.firewall.allowedUDPPorts = [ 51820 ];
   	services.ike-strip = {
   		enable = true;
   		package = ike.package.strip;
   		listenAddress = "10.78.0.2";
   		allowFrom = [ "10.78.0.1" ];
   		interface = "wg-ike";
   		# the same caps as lemma's services.ike.strip
   	};
   }
   ```

2. Its WireGuard key: `wg genkey | tee /var/lib/wireguard/wg-ike.key |
   wg pubkey` (0600, root), the public half to lemma.

On lemma:

3. The other end of the tunnel:

   ```nix
   networking.wireguard.interfaces.wg-ike = {
   	ips = [ "10.78.0.1/30" ];
   	privateKeyFile = "/var/lib/wireguard/wg-ike.key";
   	peers = [{
   		publicKey = "<strip's wg-ike public key>";
   		allowedIPs = [ "10.78.0.2/32" ];
   		endpoint = "<strip's public address>:51820";
   		persistentKeepalive = 25;
   	}];
   };
   ```

4. And the switch itself, in `lemma/ike.nix`:

   ```nix
   services.ike.strip = {
   	isolation = "remote";
   	address = "10.78.0.2";
   };
   ```

   dropping `strip-microvm.nix` and microvm.nix's host module from the
   imports if nothing else uses them.

5. Deploy strip first, then lemma. Check from lemma:

   ```sh
   wg show wg-ike
   printf 'not an image' | socat -t 10 - TCP:10.78.0.2:7070   # "no not-an-image"
   ```

What changes for ike: nothing but the address. The caps must match on
both hosts (ike reads no more than its own `maxBytes` of an upload and
believes no answer past them; the stripper refuses past its own). An
upload's bytes cross the tunnel, encrypted, and nothing is kept on the
strip host (each instance's scratch directory goes with it).

`nix/test-remote.nix` is this, two machines in a test: the stripper on
one, answering ike's address and refusing its own.

## Not there

- **ike itself on a VM of its own** is not planned (decisions.md); its
  stripper is (above).
- **A firewall rule for ike's egress** (N2) would be fog's.
