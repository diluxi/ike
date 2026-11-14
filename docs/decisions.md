# ike — decisions

Choices made where the docs left the implementation open, each with why.
Decisions lux made in answer to `questions.md` are marked (lux).

## Nix

- **`default.nix` is the entry; `flake.nix` wraps it.** fog is flake-free,
  and one set of expressions serves both worlds.
- **`pins.json` is the only pin, in fog's format, moved by `nix/pin`**
  (lux, 2026-11-14). `flake.nix` has no inputs and so no `flake.lock`: a
  lock would only have been a second list of revisions to drift.
- **nixpkgs is pinned to the revision fog pins** (`1d060086`), with the
  same url, hash and store name, so lemma0 builds ike from the nixpkgs it
  already has.
- **The module's package defaults to ike's own pin, not the system's
  nixpkgs.** The toolchain that CI tested is the one that runs, and from M1
  the strippers' output bytes name assets (P7): a host's nixpkgs bump must
  not change them unseen. *Pragmatic cost:* a second nixpkgs evaluation and,
  when the revisions differ, a larger closure. `services.ike.package`
  overrides it.
- **Hex packages are fetched by hash from `nix/hex.json`,** which `nix/lock`
  writes from `rebar.lock`, and handed to rebar3 as `_checkouts`. No rebar3
  plugin, and no fixed-output derivation whose hash has to be guessed.
- **The eqWAlizer check patches ELP's binary.** ELP unpacks eqWAlizer, a
  native image that wants `/lib64`'s loader, at run time; no sandbox has
  that loader. The check overwrites the loader's path inside ELP with
  `/build/ld.so` and puts a loader there. *A hack,* confined to
  `nix/package.nix`, x86_64-linux only; it asserts the path occurs exactly
  once, so an ELP bump that changes this fails loudly. The alternative was
  running eqWAlizer outside `nix flake check`.
- **The module is booted in a NixOS VM as a check** (`nix/test.nix`). This
  is a test of the unit, not a way to deploy: the hardening and the start
  command exist only in the module, and nothing else exercises them. Its
  first run found that the unit never started while the other three checks
  were green. It is the slow check (minutes on theorem); it matters when
  `nix/` or the release settings change, and CI runs it always.
- **Actions are pinned by major tag** (`actions/checkout@v4`,
  `cachix/install-nix-action@v31`), not by commit. *Pragmatic;* pinning by
  hash is better once someone reads the diffs on bumps.

## Deployment

- **On lemma0, as a unit, without a VM of its own** (lux, 2026-11-14;
  hazard N2, was Q9). The unit's sandboxing is the boundary. Worth another
  look at M1, when decoders and strippers start running on what strangers
  upload.

## Erlang

- **OTP 29,** current stable in the pinned nixpkgs (29.1.2).
- **One node, never distributed.** No node name, no cookie, epmd off:
  planning rules out more than one node, and a listening distribution port
  is attack surface for nothing. The unit stops with SIGTERM, which the
  BEAM turns into `init:stop/0`.
- **relx's plain start script, not the extended one.** The extended script
  refuses to start a node without a name, and its `stop`, `remote_console`
  and `rpc` all need distribution. The plain one passes its arguments to
  `erl`, so the unit runs `ike -noinput -config <file>`, and that file's
  keys override the release's `sys.config`. *Cost:* no remote shell into a
  running node. The script splits arguments with `printf '\x1f'`, which
  dash does not understand; in the store its shebang is bash.
- **PropEr is a default-profile dependency,** because `rebar.lock` covers
  no other profile and the lock is what Nix fetches from. The release
  includes only what `ike.app.src` names, so it stays out. *Pragmatic.*
- **Properties run inside Common Test suites** (`proper:quickcheck/2`),
  which saves the rebar3_proper plugin.
- **Tests are Common Test suites that start the application and then use
  only HTTP, the filesystem and the database.** Black-box in what they
  touch; they share a VM with ike for speed. The NixOS VM test
  (`nix/test.nix`) is the fully separate harness, for what needs nginx or
  a restore.
- **eqWAlizer runs over every module under `src`,** not only the typed
  core: wider than asked, and cheap while there is little code. Narrow it
  to a list if non-core code ever needs `dynamic()`.
- **"Strict mode" is not a switch in this ELP** (2026-08-10): no
  setting that turns gradual typing off shows up in its help, its
  configuration reference or its binary. What is enforced is zero eqWAlizer
  errors. Planned for step 3: the core modules may not mention `dynamic()`,
  `eqwalizer:fixme` or `eqwalizer:ignore`, checked by a test. If lux knows
  the switch that was meant, it goes in then.
- **Crash dumps are off in the unit** (`ERL_CRASH_DUMP_BYTES=0`): a dump
  holds whatever was in memory, which from M1 includes the rate limiter's
  salt and addresses (N5, invariant 1).
- **`/health`** exists so that tests and the unit have something to ask.
- **Listening on loopback, port 8970** by default; a Unix socket (N3) can
  replace it when the rate limiter arrives.
