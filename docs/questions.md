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
  asset, which outlives collected uploads. Needs a yes before M1.
- **C4 A global `>>N` and `>>>/board/N`.** If the post sequence is global,
  the board in `>>>/board/N` picks nothing that `>>N` didn't. Either the
  board is only a hint for rendering and for remote boards later, or
  numbering is per board and "Global `>>N`" is wrong. *Assumed:* one global
  sequence, and the schema is built on that.
- **C5 Flakes.** The stack names a Nix flake; fog has none and wants none.
  Not a real conflict: `default.nix` is the entry and takes its pins from
  `pins.json` as fog's does; `flake.nix` wraps it and has no inputs
  (decisions.md). Listed so it is not rediscovered.

## Assumed by the schema (step 3)

lux said to go on before answering these, so migration 0001 takes the
answer that stores least and is cheapest to change. Each is still lux's.

- **Q1 Does a post carry a time?** The post primitive lists text, an
  optional asset and an optional parent; only uploads list a time, and
  anonymous text posts "store nothing beyond their contents". A precise
  time helps correlate a post with a connection. *Assumed:* no time column;
  order is the post number. A coarse or full time is one `ALTER TABLE`
  away, but posts made before it will have none.
- **Q2 Who is the actor of a text post made while logged in?** M0's own
  test is a logged-in POST. *Assumed:* every post points at an actor, and
  anonymous is one shared row (id 1). Which actor a logged-in text post
  gets is the writer's choice in step 4, not the schema's.
- **Q4 Reply parents (open decision).** *Stub:* a nullable `parent` column
  that M0 never fills.
- **C4** above: one global sequence, no board column yet.

Q3 (the upload-to-account link, I4) and C3 (original hashes) no longer
touch M0: the schema has no upload table, since nothing uploads before M1.
`asset` is only its hash, so that a post can name one and invariant 9 has
something to test. Both questions come back with M1's migration.

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
