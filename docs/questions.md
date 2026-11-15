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
- **Q7 Authelia client**, what is left of it. The issuer is
  `https://auth.amartia.online`, the board `chike.amartia.online`. Still
  open: the client id, and whether the client is public (PKCE only) or
  confidential. Both are built. Authelia must sign id tokens with RS256
  (its default).
- **Q8 Retention** (D6, D7). *Meanwhile:* seven daily snapshots, which
  lux finds generous. They are not copy-on-write: each is a whole copy
  through SQLite's backup API, so seven cost seven times the database,
  whatever the filesystem. Small while there are no assets in it, and
  assets will not be in it. Still to answer before M1: purged content
  lives in snapshots for as long as they are kept.
- **Q13 Three hosts, one login?** Session cookies are `__Host-`
  prefixed and so belong to one host; the redirect URI names one host
  too. With three names a person logs in once per view (one redirect
  each, while Authelia remembers them), unless the cookie is widened to
  `amartia.online`, where every other subdomain could read it. Or one
  name carries login and posting and the others only show. *Meanwhile:*
  one host, the board's. To answer before a second view exists.
- **Q14 Names and user boards.** For the name on a post (decisions.md,
  Renderer) ike has to keep a nick per actor: from the provider's
  `preferred_username` (then scope `profile`, and a rename there has to
  re-render every page naming them), or chosen in ike? And which
  milestone do user boards belong to? The readme says image posts are
  shown as anonymous; this is taken to stay so, the name being for text
  posts made while logged in.

## Open decisions in planning.md

Tracked there. None is resolved here.
