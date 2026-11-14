# ike — status

Updated 2026-11-14. Milestone: **M0 Foundation**.

## Done

- **Step 1** (`phi/charter`): `phi.md` with the role, the eleven
  invariants and the rule that every change keeps them; a readme;
  `questions.md`.
- **Step 2** (`phi/skeleton`, on top of `phi/charter`): the rebar3 project
  with a Cowboy listener answering `/health`; `default.nix`, `flake.nix`
  and the NixOS module; four checks (the release, the Common Test suites
  with xref, eqWAlizer, the module booted in a VM); the GitHub Actions
  workflow; `decisions.md`; `deploying.md` for fog's side.

All four checks pass locally (`nix-build -A checks`, x86_64-linux). The
workflow itself has never run: there is no remote.

## Next

- Step 3, the schema with migrations, once the questions below are
  answered and CI has been seen green on GitHub.

## Blocked on lux

- **A GitHub repository** (Q5), to push the two branches, open their PRs
  and see CI green. Step 3 waits for that by the order of work.
- **Before step 3:** C3 (where original hashes live), C4 (one global
  `>>N`), Q1 (does a post carry a time), Q2 (the actor of a logged-in text
  post), Q3 and Q4 (whether the two stubs are acceptable).
- **Before later steps:** Q6 licence, Q7 the Authelia client, C1 nginx or
  Caddy, Q8 backups.
- **Not committed, as asked:** `docs/planning.md`, `docs/hazards.md`,
  `docs/fog.md`. `phi.md` and the readme point at the first two, so
  until they are committed a fresh clone has dangling references.
- **The cert** `phi (claude-fable-5-2)`, `4B9524FB…D3AC`, signing subkey
  for theorem `C9C4503ACBE66F6B`: its primary key is still in
  `gnupg-phi` on theorem, where the opus cert's is offline. fog's
  `lemma/certs/phi.asc` does not have the cert, which matters only once
  lemma0 should accept commits signed with it.
