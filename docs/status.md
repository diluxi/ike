# ike — status

Updated 2026-11-16. Milestones: **M2 Booru** and **M3 Wiki**, begun on lux's word (S2 lifted for the wiki) while M1 still owes a little (below).

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
6. **Assets** (`phi/assets`): done but for what is listed below; see
   decisions.md. `ike-strip` (jpegtran, libvips, a Zig chunk filter)
   in a sandboxed unit per upload behind a unix socket; uploads staged
   for their uploader through signed links on the media origin; posts
   that show one, with the media origin's files following what is
   shown; dedup; block, unblock and purge of an image by hash.
   Invariants 6, 10 and 11 are real; 2, 3, 5, 7, 8 and 9 extended.
   Assets are kept whole: colour profiles, animated PNG frames, pixels
   as stored (lux). A post shows any number of images, up to a cap.
   Nothing expires: trash replaces delete, and a purge erases a post's
   text and not its images (decisions.md, "Words").
   Still owed: uploads without an account (I4's switch, before a public
   launch), blocking a hash that no post shows,
   thumbnails on the board index, animated WebP. Waiting on lux: who
   sees staged uploads (Q31), orientation and profile text (Q32), a
   hold's end and the blocklist (Q30).
7. **Notice and action, Impressum.**

## Next

Branches past `dev`, in order, each with full checks passing:
`phi/account`, `phi/trash`, `phi/retract`, `phi/inline`, `phi/booru`,
`phi/tags`, `phi/video`, `phi/wiki`. `phi/video` and `phi/wiki` may not
be on origin: the last push gave no answer (ssh agent).

- **M1 owes:** files on the post form, the anonymous upload switch
  (still images and static meshes only, by lux's rule), vichan's "file"
  box.
- **M2 owes:** entries from `/upload`, versions and upgrades, paging,
  tag aliases and implications (BURs are M4), GIF, meshes (rule in
  decisions.md).
- **M3 owes:** renames and redirects, tag pages, the threaded view,
  promotion of a reply, static page files.

## Blocked on lux

- **Merging** the M0 stack, then `phi/board`.
- **Authelia's `groups` before deploying `phi/mod`:** ike now asks for
  the `groups` scope, and Authelia refuses a scope the client lacks, so
  every login breaks until fog's client lists it (deploying.md).
- **Step 5's stubs:** the hold period (14 days); purge and snapshots
  (Q21, Q8); hashes in purge entries (Q22); what admins do beyond
  moderators (Q29). Ranked roles are built (decisions.md).
- **Step 6's stubs:** the size caps (`services.ike.strip`); the media
  host is `cdn.amartia.online` on lux's word, same-site with ike until it
  moves (decisions.md); hashes in purge entries (Q22, none shown).
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
