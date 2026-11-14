# ike

an imageboard, a booru and a wiki for amartia.online, as three views over one
store of threads, assets and revisions. one erlang release behind a web
server; sqlite holds the truth, and every page on disk is derived from it.

- **chike**, the board: threads, read linearly or reply-threaded
- **ikooru**, the booru: curated posts over assets, with tags
- **wike**, the wiki: pages that are the op of their own thread, edits as
  replies shown as diffs

_ike_ is toki pona for bad, or as a verb, to worsen. it pairs with
amartia, from greek _hamartia_: missing the mark.

# shape

static-first html that works as plain forms with no javascript. login goes
through oidc. text posts are anonymous and store nothing beyond their
contents; image posts need an account and are shown as anonymous. no ip
address is ever written anywhere.

`docs/planning.md` is the plan, `docs/hazards.md` what can go wrong and the
eleven invariants that bind every change. `docs/status.md` says where things
stand, `docs/decisions.md` why they are the way they are.

# building

everything is pinned by `pins.json`, which `default.nix` reads on its own,
so flakes are optional:

```sh
nix-build -A package   # the release, in result/
nix-build -A checks    # what ci runs
nix-shell              # erlang, rebar3 and friends

nix build; nix flake check; nix develop   # the same, with flakes
```

inside the shell, `rebar3 shell` runs ike on 127.0.0.1:8970 and `rebar3 ct`
runs the tests. after changing dependencies, `nix/lock` rewrites
`nix/hex.json` from `rebar.lock`. `nix/pin nixpkgs nixos/nixpkgs
nixos-unstable` moves the nixpkgs pin.

# running

`nix/module.nix` is a nixos module (`services.ike`). `docs/deploying.md`
shows how a configuration without flakes takes it in.

# licence

not chosen yet.
