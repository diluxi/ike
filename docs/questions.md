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
- **Q20 Who may do what.** Planning names hide, delete, purge, ban and
  lockdown but not which role does which. Stubbed in `ike_role:may/2`:
  janitor hides/unhides, moderator all but purge, admin all. Nothing
  stops a moderator banning an admin's account, or their own (the ban
  goes through a post the account signed); should roles rank accounts?
- **Q21 Purge and the snapshots.** Invariant 8's test leaves `backups/`
  out, since a snapshot taken before a purge still holds the content
  until it ages out (D7). Is that the reading wanted, or should purge
  also rewrite or drop snapshots (or crypto-shredding, planning's open
  item)?
- **Q22 Purge entries and hashes (G5).** Text-only purges log the
  reason and the number. When assets arrive, whether the hash is shown
  is still open; nothing logs one yet.
- **Q23 Tools for the asset pipeline.** phi.md allows nothing beyond its
  stack without asking, and step 6 cannot start without: libvips (decode,
  dimensions, thumbnails), libjpeg-turbo's `jpegtran` (lossless JPEG
  stripping and orientation), a PNG/WebP chunk filter by allowlist, and
  exiftool in the tests only (the P7 inspector). The chunk filter may
  not run in ike's VM (invariant 6); it could be a small C or Zig
  program in the repo, or an escript run as its own OS process. Which
  of these may be added, and in what for the filter?
- **Q24 The sandbox for those tools.** P1 asks for each tool to run as
  its own process through an Erlang port, in a systemd unit with no
  network, seccomp, a read-only filesystem but for scratch, and limits.
  A service cannot start transient units without privilege, so the
  port's child needs a way in. Either a template unit `ike-strip@`
  (socket-activated, one instance per job, spool directory in and out),
  or the port runs each tool under bubblewrap with `prlimit`, which is
  one more dependency. The suites would run the tools unsandboxed in
  both cases, and the module test would check the sandbox. Which?
- **Q25 Staging in M1 or M2.** Planning's M2 row lists staged uploads,
  invariant 10's tripwire says they arrive in M1. If an M1 image post is
  uploaded and posted in one request, nothing is staged and invariant 10
  stays a tripwire until M2. Is that the reading?
- **Q26 Notice and action.** Planning's open decisions include "the
  takedown flow under the DSA" and the lawyer's questions (L2, L3).
  Step 7's shape follows from them: what a notice must carry, what is
  kept of whoever sends it (a name and an email address under Art. 16
  DSA, and for how long), whether ike sends a confirmation (an outgoing
  mail is a new dependency and new egress). Nothing is built until
  these are answered. An Impressum page fed from configuration does not
  wait on them, and can be done on its own if wanted.
- **Q15 Old M0 paths.** `/t/N` and `/new` are gone without redirects,
  since nothing was ever deployed under them.

## Open decisions in planning.md

Tracked there. None is resolved here.
