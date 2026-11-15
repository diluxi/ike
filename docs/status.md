# ike — status

Updated 2026-11-15. Milestone: **M0 Foundation**.

## Done

- **Step 1** (`phi/charter`): `phi.md` with the role, the eleven
  invariants and the rule that every change keeps them; a readme;
  `questions.md`.
- **Step 2** (`phi/skeleton`, on `phi/charter`): the rebar3 project with a
  Cowboy listener answering `/health`; `default.nix` pinned by `pins.json`
  and the NixOS module; four checks (the release, Common Test with xref
  and erlfmt, eqWAlizer, the module booted in a VM); the GitHub Actions
  workflow; `decisions.md`; `deploying.md` for fog's side.
- **Step 3** (`phi/schema`, on `phi/skeleton`): esqlite; migrations applied
  at start; migration 0001 with actors, the global post sequence, threads
  keyed by their root, assets as a hash, reverse links and the
  reachability view; a schema suite, which holds the first invariant test
  (9) and the schema's share of 8.
- **lux's answers** (`phi/answers`, on `phi/schema`): the flake is gone;
  `LICENSE`; `post.time`; and in `decisions.md`, Caddy in front, OIDC
  against Authelia rather than LDAP, snapshots into a directory, anonymous
  as an actor, one global sequence.

All four checks pass locally on each branch tip (`nix-build -A checks`,
x86_64-linux).

## Next

- Step 4, the single-writer gen_server: the only process holding a
  writable connection, typed ids and write capabilities, query timeouts.

## Blocked on lux

- **CI has never run.** The workflow triggers on pushes to dev and on pull
  requests, and dev does not exist on the remote yet. The order of work
  wanted CI green before step 3; that is still owed.
- **Wording in lux's documents:** invariant 8 and the blocklist, nginx in
  planning.md. Both in `questions.md`.
- **Before later steps:** C3 original hashes (M1), Q5 whether the
  repository is public (fog's pin), Q7 the Authelia client (step 6), Q8
  retention (step 7).
- **Not committed, as asked:** `docs/planning.md`, `docs/hazards.md`,
  `docs/fog.md`. `phi.md` and the readme point at the first two, so until
  they are committed a fresh clone has dangling references.
- **The cert** `phi (claude-fable-5-2)`, `4B9524FB…D3AC`, signing subkey
  for theorem `C9C4503ACBE66F6B`: its primary key is still in `gnupg-phi`
  on theorem, where the opus cert's is offline. fog's
  `lemma/certs/phi.asc` does not have the cert, which matters only once
  lemma0 should accept commits signed with it.
