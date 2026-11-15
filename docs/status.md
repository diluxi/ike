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
3. **Links** (`phi/links`): done. `>>N` and `>>>/b/N`, reverse links
   kept by the writer and shown under each post, `/p/N`, and the same
   tombstone for every link to nothing.
4. **Anonymous text posts** (`phi/anon`): done. Nobody posts on an
   unlocked board, through a form tied to the site by a cookie; every
   post is counted by address at the door and by board behind it, in
   memory. Invariant 1's test floods the limiter and searches for the
   addresses afterwards.
5. **Roles and moderation** (`phi/mod`): done in the core; see
   decisions.md. Roles from `groups`; hide, delete with a hold, restore,
   purge, ban, unban, lock, unlock at `/mod`; the log on `/board/mod`;
   invariant 8's real test. Still owed: a moderation suite of its own
   (permissions, hold expiry, ban and login, restore), module options
   for `roles` and `hold_seconds`, Authelia's `groups` in deploying.md,
   and replacing `ike_browser:unlock/2`'s SQL with the lock form.
6. **Assets:** the sandboxed pipeline, stripping with its corpus and
   determinism test, thumbnails, the media origin, uploads, hash dedup
   and hash bans; invariants 5, 6, 9 and 11 for real.
7. **Notice and action, Impressum.**

## Next

The rest of step 5 (above), then step 6. `phi/board` to `phi/mod`
are not on origin: the ssh agent refused to sign the push.

## Blocked on lux

- **Merging** the M0 stack, then `phi/board`.
- **Step 5's stubs:** the hold period (14 days); who may do what (Q20);
  purge and snapshots (Q21, Q8); hashes in purge entries (Q22).
- **Before step 6:** the upload-to-account link, plaintext or to an
  offline key (I4, Q3); which registered domain serves media; size
  caps. Each can be stubbed behind configuration, but I4 decides a
  table's shape.
- **Before step 7:** the Impressum address, and the lawyer's answers
  (L1 to L3).
- **Q18:** whether a keyed hash of an address may live in memory at
  all. Step 4's limiter assumes yes.
- **Q17:** the limiter key's lifetime. (Q19: moderators now lock and
  unlock.)
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
