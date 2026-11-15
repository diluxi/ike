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

- **C3, what is left of it.** The original hash is the upload's
  (decisions.md). G3 wants every original hash of a purged asset
  blocklisted, so those hashes have to be readable for as long as the
  asset lives: either upload rows are kept that long, or their hashes are
  copied out when an upload is collected. For M1's migration.
- **Q3 The upload-to-account link** (I4). Comes back with M1's migration;
  M0 has no upload table.
- **Q4 Reply parents** (open decision in planning.md). *Stub:* a nullable
  `parent` column that M0 never fills.
- **Q5 Is the repository public?** `./fog pin` and `fetchTarball` fetch
  GitHub's archive without credentials, so fog can pin ike only if it is.
- **Q7 Authelia client.** Step 6 needs the client id, the redirect URI's
  host (which name ike is served under), and whether the client is public
  (PKCE only) or confidential. Both are built; tests use a mock provider.
  Also: Authelia must sign id tokens with RS256 (its default).
- **Q8 Retention** (D6, D7). How many snapshots are kept, and for how
  long. *Meanwhile:* `services.ike.backup.keep`, defaulting to seven daily
  ones. Purged content would live that long in them; M1's purge has to
  know the answer.
- **Q9 Invariant 3 and the renderer.** "Every write, deletion and file
  unlink goes through the single writer." The renderer writes page files
  itself, as planning.md's diagram has it. *Meanwhile:* read as the
  database, and every deletion and unlink, being the writer's; pages are
  derived and only replaced. The test lists exactly who changes files,
  so it says so out loud. If the stricter reading is meant, page writes
  become messages to the writer.
- **Q10 How an account's post is shown.** It stores the account's actor
  and shows nothing. Anonymous to readers, like image posts are planned
  to be? A name? Not needed before M1.
- **Q11 Tripwires.** Five of the eleven invariant tests can only assert
  that their subject does not exist yet (decisions.md). Is that enough
  for M0's "the 11 invariants as CI tests"?
- **Q12 Sessions across restarts.** They are in memory, so a deploy logs
  everyone out. Keeping them needs either a table (then who is logged in
  is on disk) or signed cookies (then a key to keep).

## Open decisions in planning.md

Tracked there. None is resolved here.
