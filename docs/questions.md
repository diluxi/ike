# ike — questions

What lux has to decide, and what stands in for the answer meanwhile. An
answered question moves to `decisions.md` with its answer.

## Wording that lux's documents still owe

Answered in substance; the documents are lux's, so they are not edited
here.

- **Invariant 8 and the blocklist** (was C2). lux: hashes are no problem to
  keep; what they were derived from is purged. So purge leaves the mod-log
  entry *and* the blocklisted hashes, and hazards.md's invariant 8 names
  only the first. *Proposed wording:* "…referencing the content, except
  the mod-log entry and the blocklisted hashes". The test in M1 will be
  written to that unless lux says otherwise.
- **nginx in planning.md** (was C1). Caddy was chosen (decisions.md);
  planning.md's stack, and M0's "a page nginx serves", still say nginx.

## Open

- **Q3 The upload-to-account link** (I4). Comes back with M1's migration;
  M0 has no upload table.
- **Q4 Reply parents** (open decision in planning.md). *Stub:* a nullable
  `parent` column that M0 never fills.
- **Q8 Retention** (D6, D7). *Meanwhile:* seven daily snapshots, which
  lux finds generous. They are not copy-on-write: each is a whole copy
  through SQLite's backup API, so seven cost seven times the database,
  whatever the filesystem. Small while there are no assets in it, and
  assets will not be in it. Still to answer before M1: purged content
  lives in snapshots for as long as they are kept.
- **Q14 User boards.** `/user/<nick>` as a board with the bio pinned is
  recorded (decisions.md). planning.md has user boards in M6; the name
  on a post will link there once they exist, and to nothing before.
  Sooner than M6?
- **Q16 Unsigned posts by accounts.** While a board is locked, only
  accounts post on it, and an account that does not tick "post as"
  leaves a post no moderator or operator can trace to it: an account
  ban cannot follow from such a post. That is what planning.md says of
  text posts, and the opposite of what it says of uploads (I4).
  *Meanwhile:* no link at all. If locked boards should keep one, it is
  I4's table with posts in it as well, and I4's answer decides its
  shape.
- **Q17 How long the limiter's key lives** (N5: an open decision in
  planning.md). *Stub:* `salt_seconds`, an hour by default. Shorter
  forgets sooner and limits less: nothing counted by address can span
  two keys.
- **Q18 An address in memory.** phi.md says never to log or store an
  address or anything derived from one; invariant 1 says written to
  disk or logs; planning.md asks for the limiter. The limiter holds a
  keyed hash of an address in memory for at most `salt_seconds`, and
  that is all (decisions.md). If "store" is meant to cover memory too,
  the limiter can only count by board, and step 4's address limit
  goes. A crash dump would hold the table; the module turns dumps off.
- **Q19 Unlocking a board.** Nothing does it yet. A moderator's
  action in step 5, or the operator's in configuration, or both?
- **Q21 Purge and the snapshots.** Invariant 8's test leaves `backups/`
  out, since a snapshot taken before a purge still holds the content
  until it ages out (D7). Is that the reading wanted, or should purge
  also rewrite or drop snapshots (or crypto-shredding, planning's open
  item)?
- **Q22 Purge entries and hashes (G5).** Text-only purges log the
  reason and the number. When assets arrive, whether the hash is shown
  is still open; nothing logs one yet.
- **Q29 What admins do beyond moderators.** lux: "access to logs,
  trigger read-only, etc." Which logs (the `action` rows naming the
  account, the journal?), and what read-only means (no posts at all, or
  no posts by nobody)? Not built.
- **Q31 Who sees staged uploads.** lux, 2026-11-16: moderators should
  see and search everyone's uploads, as on Danbooru, where all uploads
  are public with their metadata; private ones may make sense later,
  with ActivityPub. Invariant 10 says a staged upload is served to no one
  but its uploader, and phi.md forbids a change that cannot keep an
  invariant, so nothing is built until hazards.md says which: staged
  uploads public to everyone (invariant 10 dropped or turned around),
  visible to moderators as well (its wording widened), or private by
  default with a public switch per upload. Recognition tags (Danbooru's
  AI tags, hidden while tagging) belong with tags, in M2.
- **Q32 Orientation and profile text.** With nothing turned, a phone
  photo whose camera wrote an orientation tag now shows on its side.
  Keeping that one tag (no pixel changed, a few bytes of EXIF that say
  nothing about anyone) would fix it, if wanted. And a kept profile's
  own text tags (its description) may name a device; blanking them
  leaves colour alone. Neither is built.
- **Q33 Asking after the first deploy (2026-11-16).** lux's answers so
  far: hiding and deleting never destroy or block an image (was Q30);
  files on the post form; uploads without an account behind an admin's
  switch, still images only (against A1 as written). Open:
  - after a delete's hold, does the text still go for good (planning
    lines 167, 200)? If it goes and its images stay, it is not a purge;
  - deleting one's own post: not a moderation; for an unsigned post, a
    per-browser secret in a cookie and a keyed hash of it per post
    (beyond "nothing but contents", planning line 11);
  - "svf": SWF (M6, P8) or SVG (never, P5)?
  - moderating from the boards: pages made per request for anyone
    logged in, static for everyone else;
  - meshes, Live2D, MMD: as opaque downloads from a sandboxed origin
    without previews, or wait until previews (JavaScript) are allowed;
  - the wiki before the public launch means lifting S2.
- **Q15 Old M0 paths.** `/t/N` and `/new` are gone without redirects,
  since nothing was ever deployed under them.

## Open decisions in planning.md

Tracked there. None is resolved here.
