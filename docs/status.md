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
5. **Roles and moderation** (`phi/mod`): done; see decisions.md. Roles
   from `groups`; hide, delete with a hold, restore, purge, ban, unban,
   lock, unlock at `/mod`; the log on `/board/mod`; invariant 8's real
   test, and `ike_mod_SUITE`. The first commit extended only invariant
   4's class list; invariants 2, 4 and 8 caught up one commit later
   (0377cc7), against phi.md's same-commit rule. Suites still open
   boards by SQL for setup, so that the log's posts do not shift their
   numbers; the lock form is tested in `ike_mod_SUITE`.
6. **Assets:** the sandboxed pipeline, stripping with its corpus and
   determinism test, thumbnails, the media origin, uploads, hash dedup
   and hash bans; invariants 5, 6, 9 and 11 for real.
7. **Notice and action, Impressum.**

## Next

Nothing that can start without lux: step 6 and step 7 both wait on
the answers below. Origin has `phi/mod` up to 1945743; the commits
after it wait on the ssh agent, which refused to sign the push.

## Blocked on lux

- **Merging** the M0 stack, then `phi/board`.
- **Authelia's `groups` before deploying `phi/mod`:** ike now asks for
  the `groups` scope, and Authelia refuses a scope the client lacks, so
  every login breaks until fog's client lists it (deploying.md).
- **Step 5's stubs:** the hold period (14 days); who may do what (Q20);
  purge and snapshots (Q21, Q8); hashes in purge entries (Q22).
- **Before step 6**, which cannot start in pieces: its first commit has
  to bring the port runner, a stripper, the fixture corpus and the
  determinism test together, since invariants 3, 5, 6 and 11 all change
  with it. Needed: the tools (Q23), the sandbox's shape (Q24), staging
  in M1 or M2 (Q25), the upload-to-account link (I4, Q3), the media
  domain, size caps.
- **Before step 7:** the takedown flow and the lawyer's answers (Q26,
  L2, L3); the Impressum address (L1). An Impressum page from
  configuration could come first on its own.
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
