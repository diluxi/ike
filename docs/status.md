# ike — status

Updated 2026-11-15. Milestone: **M1 Board**, started on lux's word.

## M0

Done, on `phi/writer` → `phi/render` → `phi/login` → `phi/backup` →
`phi/invariants` → `phi/sessions`, all on origin and waiting to be
merged in that order. `nix-build -A checks` passes on the tips of the
last four; the first two were checked with the VM test and the host's
rebar3 and eqWAlizer as they were written.

## M1, in steps

Each a branch on the one before, starting from `phi/sessions`.

1. **Boards and paths** (`phi/board`): done. Boards from configuration,
   locked when new; `/board`, `/board/b`, `/board/b/N`; one host.
2. **Names** (`phi/names`): done. A nick from `preferred_username`;
   the name on a post only when its account ticks "post as", and one of
   the server's names for nobody otherwise.
3. **Links:** `>>N` and `>>>/b/N` in text, reverse links, tombstones.
4. **Anonymous text posts** on unlocked boards, behind the rate limiter
   (N3 to N5); invariant 1's test grows with it.
5. **Roles and moderation:** `groups` claim; hide, delete, purge,
   account ban, lockdown; the mod log; invariant 8's real test.
6. **Assets:** the sandboxed pipeline, stripping with its corpus and
   determinism test, thumbnails, the media origin, uploads, hash dedup
   and hash bans; invariants 5, 6, 9 and 11 for real.
7. **Notice and action, Impressum.**

## Next

Step 3.

## Blocked on lux

- **Merging** the M0 stack, then `phi/board`.
- **Before step 5:** the hold period between delete and purge; whether
  purge entries in the mod log show hashes (G5); retention (Q8), since
  purged content lives on in snapshots that long.
- **Before step 6:** the upload-to-account link, plaintext or to an
  offline key (I4, Q3); which registered domain serves media; size
  caps. Each can be stubbed behind configuration, but I4 decides a
  table's shape.
- **Before step 7:** the Impressum address, and the lawyer's answers
  (L1 to L3).
- **Q14:** whether user boards come before M6.
- **Q16:** whether an unsigned post on a locked board may stay
  untraceable to its account.
- **Authelia:** a claims policy putting `preferred_username` in the id
  token (deploying.md), or nobody has a name.
- **Wording in lux's documents:** invariant 8 and the blocklist, nginx
  and the three host names in planning.md.
- **Not committed, as asked:** `docs/planning.md`, `docs/hazards.md`,
  `docs/fog.md`.
- **The cert:** fog's `lemma/certs/phi.asc` lacks the signing cert used
  here.
