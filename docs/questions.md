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

- **C3 Where the original hash lives.** Not about similarity hashes: this
  is the SHA-256 of the bytes as uploaded, before stripping. Two uploads
  that differ only in metadata strip to the same stored asset, so one
  asset has several original hashes, and G3 wants each of them blocklisted
  on purge so the same file cannot be re-uploaded. planning.md gives the
  asset one "original upload's hash". *Proposed:* a table of original
  hashes per asset. Perceptual hashes are a separate matter (and a
  separate column). Needs a yes before M1.
- **Q3 The upload-to-account link** (I4). Comes back with M1's migration;
  M0 has no upload table.
- **Q4 Reply parents** (open decision in planning.md). *Stub:* a nullable
  `parent` column that M0 never fills.
- **Q5 Is the repository public?** `./fog pin` and `fetchTarball` fetch
  GitHub's archive without credentials, so fog can pin ike only if it is.
- **Q7 Authelia client.** Step 6 needs the client id, the redirect URI's
  host (which name ike is served under), and whether the client is public
  (PKCE only) or confidential. Tests use a mock IdP either way.
- **Q8 Retention** (D6, D7). How many snapshots are kept, and for how
  long. *Meanwhile:* an option, defaulting to seven.

## Open decisions in planning.md

Tracked there. None is resolved here.
