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
- **Q15 Old M0 paths.** `/t/N` and `/new` are gone without redirects,
  since nothing was ever deployed under them.

## Open decisions in planning.md

Tracked there. None is resolved here.
