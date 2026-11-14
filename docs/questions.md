# ike — questions

What lux has to decide, and what stands in for the answer meanwhile. An
answered question moves to `decisions.md` with its answer.

## Contradictions found

- **C1 nginx or Caddy.** planning.md puts nginx in front of ike (static
  pages, `limit_req`, `client_max_body_size`; M0 is done when "a page nginx
  serves" is regenerated). lemma0, where ike will run (decisions.md),
  already has Caddy on 80 and 443 for every other service. So it is nginx
  behind Caddy, or Caddy alone, whose rate limiting is a plugin.
  *Meanwhile:* the tests run nginx, and the module's web server part is a
  separate option, off by default.
- **C2 Invariant 8 against the blocklist.** Purge "leaves no row … referencing
  the content, except the mod-log entry", yet purge also puts the stored hash
  and every original hash on a blocklist (planning, Moderation; G3), which is
  a row referencing the content. Either the invariant's exception names the
  blocklist too, or the blocklist holds something other than the hash. This
  touches G5's open question on hashes in the mod log. Not needed before M1.
- **C3 Where the original hash lives.** The asset is said to keep "the
  original upload's hash", singular; G3 speaks of "every original hash seen
  for it", and dedup maps many originals onto one stored asset. One column
  on the asset cannot hold that. *Proposed:* a table of original hashes per
  asset, which outlives collected uploads. Needs a yes before step 3.
- **C4 A global `>>N` and `>>>/board/N`.** If the post sequence is global,
  the board in `>>>/board/N` picks nothing that `>>N` didn't. Either the
  board is only a hint for rendering and for remote boards later, or
  numbering is per board and "Global `>>N`" is wrong. *Assumed:* one global
  sequence. Needs a yes before step 3.
- **C5 Flakes.** The stack names a Nix flake; fog has none and wants none.
  Not a real conflict: `default.nix` is the entry and takes its pins from
  `pins.json` as fog's does; `flake.nix` wraps it and has no inputs
  (decisions.md). Listed so it is not rediscovered.

## Blocking step 3 (schema)

- **Q1 Does a post carry a time?** The post primitive lists text, an
  optional asset and an optional parent; only uploads list a time, and
  anonymous text posts "store nothing beyond their contents". A board
  without timestamps is unusual, and a precise one helps correlate a post
  with a connection. No time, a coarse one (minute, hour), or a full one?
- **Q2 Who is the actor of a text post made while logged in?** M0's own test
  is a logged-in POST. Is that post the account's, or the anonymous actor's
  like an image post's would be shown? *Proposed:* posts always point at an
  actor; anonymous is one shared row.
- **Q3 The upload-to-account link (I4, open decision).** The uploads table
  is in M0. *Stub:* the column is an opaque blob written and read only
  through one module, whose M0 implementation stores the actor id as is; an
  encrypting one can replace it without a schema change. Since no upload
  exists before M1, nothing is committed to either answer. Is that stub
  acceptable?
- **Q4 Reply parents (open decision).** The post's optional parent is in the
  schema; whether it is the first `>>N` or chosen explicitly is open.
  *Stub:* a nullable column that M0 never fills.

## Blocking later steps of M0

- **Q5 A remote.** CI has to be green before step 3 and every step is a PR,
  so the repository has to exist on GitHub. `./fog pin` fetches an
  unauthenticated archive, so it would have to be public, or fog needs
  another way to fetch it.
- **Q6 Licence.** AGPL-3.0 or something else. The readme says "not chosen
  yet" and there is no licence file.
- **Q7 Authelia client.** Step 6 needs the client id, the redirect URI's
  host (which name ike is served under), and whether the client is public
  (PKCE only) or confidential. Tests use a mock IdP either way.
- **Q8 Backup tool and retention (D6, D7; open decision).** Step 7 will
  snapshot through the SQLite backup API into a directory and leave shipping
  it elsewhere to a swappable command.

## Open decisions in planning.md

Tracked there. None is resolved here.
