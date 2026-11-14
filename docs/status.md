# ike — status

Updated 2026-11-14. Milestone: **M0 Foundation**.

## Done

- **Step 1** (`phi/charter`): `phi.md` with the role, the eleven
  invariants and the rule that every change keeps them; a readme;
  `questions.md`.
- **Step 2** (`phi/skeleton`, on `phi/charter`): the rebar3 project with a
  Cowboy listener answering `/health`; `default.nix` pinned by `pins.json`,
  an input-less `flake.nix` and the NixOS module; four checks (the release,
  Common Test with xref and erlfmt, eqWAlizer, the module booted in a VM);
  the GitHub Actions workflow; `decisions.md`; `deploying.md` for fog's
  side.
- **Step 3** (`phi/schema`, on `phi/skeleton`): esqlite; migrations applied
  at start; migration 0001 with actors, the global post sequence, threads
  keyed by their root, assets as a hash, reverse links and the
  reachability view; a schema suite, which holds the first invariant test
  (9) and the schema's share of 8.

All four checks pass locally on each branch tip (`nix-build -A checks`,
x86_64-linux). The workflow itself has never run: there is no remote.

## Next

- Step 4, the single-writer gen_server: the only process holding a
  writable connection, typed ids and write capabilities, query timeouts.

## Blocked on lux

- **A GitHub repository** (Q5), to push the three branches, open their PRs
  and see CI run for the first time. The order of work wanted CI green
  before step 3; lux said to go on, so that is still owed.
- **Assumed, not decided:** Q1 (no post time), Q2 (every post has an
  actor), Q4 (nullable parent), C4 (one global sequence). All in
  `questions.md`.
- **Before later steps:** Q6 licence, Q7 the Authelia client, C1 nginx or
  Caddy, Q8 backups.
- **Not committed, as asked:** `docs/planning.md`, `docs/hazards.md`,
  `docs/fog.md`. `phi.md` and the readme point at the first two, so until
  they are committed a fresh clone has dangling references.
- **The cert** `phi (claude-fable-5-2)`, `4B9524FB…D3AC`, signing subkey
  for theorem `C9C4503ACBE66F6B`: its primary key is still in `gnupg-phi`
  on theorem, where the opus cert's is offline. fog's
  `lemma/certs/phi.asc` does not have the cert, which matters only once
  lemma0 should accept commits signed with it.
