# ike — hazards

Nov 9, 2026 · lux · Sister to `ike/planning.md`: what can go wrong, what closes it, and by when. Revised the same day against the revised planning.md.

## Overview

Hazards are ranked by consequence, not likelihood. A single operator running an anonymous text board with account-gated image uploads in Germany fails worst through content, legal exposure and host compromise, so those dominate the top of the list. Each hazard names the milestone by which it must be closed and one of four statuses.

- **Closed by design.** A decision in planning.md removes the hazard; it needs only to be kept, and usually a test keeps it.
- **Mitigated.** A control is specified; it still needs implementation and a test that proves it.
- **Open.** It needs a decision from lux or an outside source (a lawyer, an authority).
- **Accepted.** The residual risk is judged tolerable and written down.

## Summary

| ID | Hazard | Severity | Closes by | Status |
| --- | --- | --- | --- | --- |
| A1 | Anonymous image uploads as a CSAM target | Critical | Launch gate | Closed by design |
| P1 | Exploits in decoders and metadata strippers | Critical | M1 | Mitigated |
| I3 | XSS through the renderer or the link grammar | Critical | M0 | Mitigated |
| N1 | SSRF through external fetching | Critical | Before any adapter | Mitigated |
| L3 | CSAM: retention and evidence preservation | Critical | M1 | Open (hold exclusion adopted) |
| G3 | Purge defeated by surviving strong references | Critical | M1 | Mitigated |
| A2 | Spam from unlimited anonymous identities | High | M1 | Mitigated |
| A4 | Raids and floods | High | M1 | Mitigated |
| P2 | Decompression bombs and resource exhaustion | High | M1 | Mitigated |
| P3 | Polyglot files and content sniffing on the main origin | High | M1 | Closed by design |
| P4 | Metadata retention versus asset identity | High | M0 | Closed by design |
| P7 | Incomplete or non-deterministic lossless stripping | High | M1 | Mitigated |
| P8 | Executable media sharing the media origin | High | M6 | Open |
| N2 | Blast radius: shared host with Authelia and LLDAP | High | Launch gate | Open |
| N3 | Spoofed X-Forwarded-For defeating the rate limiter | High | M1 | Mitigated |
| I1 | OIDC implementation flaws | High | M0 | Mitigated |
| I2 | CSRF on plain forms | High | M0 | Mitigated |
| D1 | Stale static pages after delete or purge | High | M0 | Mitigated |
| D3 | Purge breaking diff-stored revision chains | High | M0 schema | Closed by design |
| D6 | No backups of the single source of truth | High | Launch gate | Open |
| D7 | Purged and collected content surviving in backups | High | Launch gate | Open |
| G1 | Sweep racing in-flight uploads and dedup hits | High | M2 | Mitigated |
| G6 | A faulty reachability query mass-deleting live assets | High | M2 | Mitigated |
| L1 | Impressum exposing the operator's address | High | Launch gate | Open |
| L2 | DSA hosting duties | High | Launch gate | Open |
| S1 | Agent drift from the invariants | High | Continuous | Mitigated |
| S2 | Scope breadth | High | Continuous | Mitigated |
| A3 | Hash bans evaded by re-encoding | Medium | M2 | Open |
| N4 | IPv6 addresses keyed per /128 | Medium | M1 | Mitigated |
| N5 | Salt leak making IPv4 hashes reversible | Medium | M1 | Mitigated |
| N6 | Per-request search and tag pages as a DoS surface | Medium | M2 | Mitigated |
| N7 | Fetch and archive amplification from anonymous posts | Medium | Before any adapter | Mitigated |
| I4 | Upload-to-account link: plaintext or offline key | Medium | M1 | Open (narrowed) |
| I5 | Stale roles from the `groups` claim | Medium | M1 | Mitigated |
| D2 | Non-atomic page writes | Medium | M0 | Mitigated |
| D4 | Mnesia diverging from SQLite | Medium | M0 | Closed by design |
| D5 | SQLite NIF stalling BEAM schedulers | Medium | M0 | Mitigated |
| G2 | Redirect cycles, long chains and name squatting | Medium | M3 | Mitigated |
| G4 | Re-render storms when a popular target changes | Medium | M3 | Mitigated |
| G7 | Staged uploads as an unmoderated hosting channel | Medium | M2 | Mitigated |
| L4 | Licences of snapshots and adopted images | Medium | M5 | Mitigated |
| S3 | Review as the bottleneck | Medium | Continuous | Mitigated |
| G5 | Tombstones and the mod log leaking what existed | Low | M1 | Open |
| P6 | Dedup as a hash-existence oracle | Low | M2 | Accepted |
| D8 | Mass edits monopolising the single writer | Low | M4 | Mitigated |
| L5 | Archive submission leaking private URLs | Low | M5 | Mitigated |

## Abuse and content

- **A1 Anonymous image uploads.** An open, unauthenticated image host run by one person is a CSAM-upload target from the first day it is indexed.
  - Closed by design: text posts are anonymous without login; image posts need an account and are *displayed* as anonymous (planning, Constraints). Opening anonymous image posting on any board reopens this hazard and needs its own review.
  - Consequence: the upload-to-account link must exist, which narrows I4. "Nothing stored beyond contents" now holds for anonymous text posts only.
  - Test: an unauthenticated multipart POST with a file is rejected before the asset pipeline touches the bytes.
- **A2 Unlimited identities.** With no stored identifiers, Tor and VPN users get a fresh identity per request. Proof of work in the style of hashcash (Adam Back, 1997) needs JS, which the constraints forbid as a requirement.
  - Control: the in-memory rate limiter, per-board cooldowns, a JS-free captcha on anonymous posts if needed, and account gating as the fallback. A1 already limits the worst case to text.
- **A3 Hash bans are evadable.** SHA-256 bans miss any re-encoded copy.
  - Control: the perceptual hash flags near-duplicates into the moderation queue and never bans automatically (planning, Moderation). External known-hash lists remain an open question of access.
- **A4 Raids.** Control: lockdown is the default state for new boards (planning, Moderation), plus per-board cooldowns that moderators can tighten without a deploy.

## Asset pipeline

- **P1 Decoder and stripper exploits.** Image libraries are a long-running exploit surface; ImageTragick (CVE-2016-3714, 2016) let crafted files execute commands through ImageMagick. Lossless stripping (P4) parses hostile input just as decoding does.
  - Control: libvips (John Cupitt, around 1990) rather than ImageMagick. Every decoder and stripper (libvips, jpegtran, the PNG/WebP chunk filter, ffmpeg, ffprobe) runs as a separate OS process through an Erlang port, in a systemd unit with no network, seccomp filtering, `PrivateTmp`, a read-only filesystem except its scratch dir, and CPU, memory and time limits.
- **P2 Decompression bombs.** Control: read dimensions and frame counts from headers before decoding; reject past per-type caps. Byte limits in nginx (`client_max_body_size`) before ike sees the upload.
- **P3 Polyglots and sniffing.** A file can be a valid image and valid HTML or JS at once.
  - Closed by design: all user media is served from a separate cookieless registered domain with `nosniff`, a restrictive CSP, and extensions taken from the validated type (planning, Media types). Invariant 5 keeps it.
- **P4 Metadata versus identity.** If identity were the hash of the original upload, ike would either keep the original, GPS included, or name bytes it does not have.
  - Closed by design: metadata is stripped losslessly (`jpegtran -copy none`, PNG and WebP chunk removal, `ffmpeg -map_metadata -1 -c copy`), never re-encoded. Asset identity is the SHA-256 of the stored, stripped bytes; the original upload's hash sits in its own column for matching and bans. Pixels match the upload; location and camera data are gone. Whether the stripping is actually complete is P7.
- **P5 SVG.** Never accepted as an asset (planning, Media types). If ever needed, rasterise it in the sandbox and store only the raster.
- **P6 Hash-existence oracle.** Dedup tells an uploader whether a file already exists. Accepted as low risk, now limited to logged-in uploaders by A1; a purged-hash rejection must read the same as any other refusal.
- **P7 Incomplete or non-deterministic stripping.** Lossless stripping removes only what it knows about, and the listed commands have gaps.
  - JPEG: `jpegtran -copy none` drops APPn and COM segments and anything after EOI. EXIF orientation goes with them, so apply it losslessly first (`jpegtran -rotate`/`-flip`, with `-trim` when edges are not MCU-aligned), or images display sideways.
  - PNG and WebP: filter by allowlist, not denylist. Keep only the chunks needed to display the image (for PNG: `IHDR`, `PLTE`, `IDAT`, `IEND`, `tRNS`, `gAMA`, `cHRM`, `sRGB`), and drop everything after `IEND` or past the RIFF length. ICC profiles can carry device names in their description strings; keep a profile only if it matches a known standard profile, otherwise drop it and accept the colour shift.
  - Video: `-map_metadata -1` clears container and stream tags, but default stream selection is not an allowlist, and some cameras record GPS as a separate data track (GoPro's GPMF telemetry, for one). Map streams explicitly (one video, one audio), add `-map_chapters -1`, and use `-fflags +bitexact` so the output carries no muxer version.
  - Determinism: dedup and bans assume that the same pixels with different metadata strip to the same bytes. Pin every tool's version in Nix; a version bump can change stored hashes for new uploads, so treat it as a migration.
  - Test: a fixture corpus with EXIF GPS, XMP, IPTC, a named ICC profile, trailing data, a GPMF track and chapter titles; after stripping, an inspector such as exiftool reports nothing outside the allowlist. A second test asserts that two copies differing only in metadata produce the same stored hash.
- **P8 Executable media on the media origin.** Interactive bundles (Ruffle SWF, HTML5) are planned for M6 in a sandboxed iframe. If they are served from the same origin as all other media, one bundle can register a service worker there and rewrite every image the site serves.
  - Control, to decide before M6: serve executable media with a `Content-Security-Policy: sandbox` response header, giving it an opaque origin that cannot register a service worker. Embed it in an `<iframe sandbox>` without `allow-same-origin`. Or give each bundle its own origin, such as a hash subdomain. Never put executable media on the image origin as an ordinary file.

## Network and host

- **N1 SSRF.** A user-supplied URL handed to a generic Open Graph or oEmbed adapter can reach Authelia, LLDAP, other local services and WireGuard peers.
  - Control: resolve DNS yourself and refuse loopback, RFC 1918, link-local, CGNAT, IPv6 ULA and the WireGuard ranges; re-check after every redirect; cap response size and time. Better, run the fetcher in its own network namespace or systemd unit with egress only. Invariant 7 keeps it.
- **N2 Blast radius.** A compromise of the asset pipeline lands on the same host as the identity provider. Now a launch-gate item in planning.md.
  - Control: a separate VM or host for ike (M0 prefers one). Failing that, `DynamicUser`, `ProtectSystem=strict`, `ProtectHome`, no access to other services' sockets or state, and a firewall rule limiting ike's own egress.
- **N3 Spoofed forwarding headers.** Control: honour `X-Forwarded-For` only from nginx's address (or a Unix socket), and have nginx overwrite rather than append it.
- **N4 IPv6.** Control: key the rate limiter on the /64 (configurable to /56), not the full address.
- **N5 Salt leak.** The IPv4 space is small enough that a salted hash is reversible once the salt is known. Control: the salt lives in memory only and rotates; nothing derived from it reaches disk or logs, crash dumps included.
- **N6 Dynamic pages as a DoS surface.** Tag pages and search now render per request in Cowboy, which resolved the conflict with invariant 2. It also means these are the one route nginx cannot serve from disk, so a flood aimed there reaches SQLite.
  - Control: `limit_req` in nginx on the dynamic routes; caps on query terms and FTS5 prefix length; per-query timeouts (D5); a short-lived ETS cache of rendered results keyed by the normalised query.
- **N7 Fetch and archive amplification.** If any link in an anonymous post triggers a fetch and an archive submission, anyone can make ike fetch arbitrary URLs. That reflects traffic at a victim host, spams the archives, and pulls whatever sits at the URL through ike's own network connection.
  - Control: fetch and submit only for links that survive a delay with no moderation action against the post, or that appear in curated objects (tags, wiki pages, booru sources); per-host rate limits as planned; never download a page's linked images during snapshotting.

## Identity and sessions

- **I1 OIDC.** Control: authorization code flow with PKCE (RFC 7636, 2015, Nat Sakimura, John Bradley, Naveen Agarwal); validate `state` and `nonce`; verify the id_token signature against the issuer's JWKS; pin the issuer and audience.
- **I2 CSRF.** Without JS, forms are the entire attack surface. Control: session cookies `HttpOnly`, `Secure`, `SameSite=Lax`; a per-session CSRF token on every authenticated form; moderator actions POST-only.
- **I3 XSS.** The link grammar and any markup make the renderer a parser of hostile input.
  - Control: the markup parser emits a tree; the renderer escapes every text node by construction, never concatenating strings into HTML. Link targets are resolved, not echoed. Property tests feed generated hostile input and assert no unescaped `<` reaches the output. The per-request renderers for tag pages and search must share the same escaping path as the static renderer.
- **I4 The upload-to-account link.** A1 makes the link mandatory for image uploads; the remaining question is how it is stored.
  - Plaintext: anyone who compromises the server, and any legal order, can tie a displayed-anonymous image to an account.
  - Encrypted to a public key whose private half stays offline: a compromise of the server alone does not reveal the link, but moderating a ban then needs the offline key. A legal order can still compel it.
  - Decision needed before M1. The UI states which one applies (planning, Moderation).
- **I5 Stale roles.** Control: roles come from the `groups` claim at login and are bound to a short-lived session, so an LLDAP group removal takes effect within that lifetime.

## Data integrity

- **D1 Static-render fan-out.** A post in one thread dirties every page that quotes it.
  - Mitigated: the reverse-link table is in M0, kept by the writer in the same transaction (planning, Architecture). It still needs a test that delete and purge rebuild every page listed for the target.
- **D2 Torn pages.** Control: render to a temporary file in the same directory, then `rename(2)`.
- **D3 Purge versus diff chains.** Closed by design: each revision stores its full text; diffs are computed at render time.
- **D4 Mnesia divergence.** Closed by design: Mnesia is dropped; SQLite is the only store, ETS covers anything hotter.
- **D5 NIF stalls.** A long query inside a SQLite NIF (for example esqlite, Maas-Maarten Zeeman) can block a scheduler. Control: dirty schedulers, timeouts, bounded FTS5 queries.
- **D6 Backups.** Now an M0 feature and a launch-gate item. Control: continuous replication with Litestream (Ben Johnson, 2021) or periodic snapshots through the SQLite backup API, plus the media store, with a tested restore. Open until a tool is chosen.
- **D7 Purged and collected content in backups.** The GC sweep widens this: collected files survive too, not only purged ones. Ordinary collection can live with the retention window; purged content may not.
  - Decision needed: a retention window short enough to accept for purges, or crypto-shredding (each asset encrypted under its own key; purge destroys the key, so every backup copy becomes unreadable). Planning's launch gate should name D7 alongside D6, since the backup tool choice decides it.
- **D8 Writer monopoly.** Control: mass edits and GC deletions apply in chunks between ordinary writes.

## Garbage collection and references

The model (planning, Garbage collection and references) follows the Nix store: posts and live staged uploads are roots, strong references keep things alive, weak references in text never do, and a scheduled sweep deletes the unreachable set through the single writer after a grace period.

- **G1 Sweep races.** The sweep computes the unreachable set at one moment and deletes at another. Between them a dedup hit can attach a new upload to an asset that is queued for deletion, or a post can commit that references it. Files add a second race: a new upload renames its file into the hash path just as the sweep unlinks that path.
  - Control: the writer re-checks reachability inside each delete transaction (`DELETE … WHERE NOT EXISTS` over the strong-reference view) rather than trusting the precomputed set. Measure the grace period from the last time a reference was removed, not from creation. File operations go through the writer too: it unlinks after commit, and it performs the final rename of new asset files, so the two cannot interleave.
  - Test: a property test that interleaves uploads, dedup hits, posts and sweeps and asserts that every referenced asset has its file.
- **G2 Redirects.** Renames, aliases and merges can form cycles (A → B → A) and long chains. A vacated name raises a squatting question: does a new page at an old name beat the redirect?
  - Control: the writer resolves a new redirect's target to its terminal and rejects it if that reaches the source. Every redirect stores its terminal and is updated in the same transaction when a chain extends, the path compression of union–find (Bernard Galler, Michael Fischer, 1964). The resolver bounds hops anyway and renders a tombstone past the bound. An existing page beats a redirect, and claiming a redirected name is a proposal.
- **G3 Purge versus strong references.** Purge must win over every strong reference: board posts pinning the asset as posted, booru version lists, staged uploads, other posts carrying the same bytes. If purge is implemented as "remove one root and let the sweep collect", any other strong reference keeps illegal content alive.
  - Control: purge targets the asset by its stored hash, not the post. In one writer transaction it removes every strong reference to it, turning the referencing posts' files into tombstones while their text stays, unless that text is purged too. The stored hash and every original hash seen for it go on the blocklist. The append-only booru version list must therefore tolerate gaps. Invariant 8 is the test.
  - Copied text is out of reach of the reverse-link table: a post that quotes purged text verbatim instead of linking `>>N` survives unless a moderator purges it as well.
- **G4 Re-render storms.** Renaming a popular tag or moving a heavily linked page can queue thousands of re-renders, and repeated edits can be used to trigger them on purpose.
  - Control: static pages emit links to stable names (`/w/name`, `/p/N`) and let the redirect table resolve them at request time, so renames and upgrades need no re-render at all. Re-rendering is reserved for changes in what a page *displays*: tombstones, and inlined quotes. The render queue is a deduplicated set, coalesced and rate-limited, and runs behind ordinary commits.
- **G5 Tombstones and the mod log.** A tombstone confirms that `>>N` existed, which the global sequence already reveals. The public mod log goes further: a purge entry with the asset hash lets anyone holding a file confirm it was on ike.
  - Control: a single tombstone wording for hide, delete and purge alike. Decision needed: whether purge entries in the public log show the hash, or only a reason category with the hash kept in an admin-only table. If the latter, invariant 8's exception changes accordingly.
- **G6 A faulty reachability query.** The sweep is only as correct as the query that defines reachability. A new table holding an asset reference that is missing from that query (the drift S1 describes) makes the sweep delete live files en masse.
  - Control: reachability is one SQL view, and a schema test fails if any column referencing assets is absent from it. Each sweep run has a cap, aborting if it would delete more than a set fraction or count. Deleted files move to a quarantine directory first and are unlinked only after a second grace period, the way `git gc` prunes only objects older than its expiry (Linus Torvalds, 2005).
- **G7 Staged uploads as a hidden channel.** Unattached uploads appear in no thread, so moderators never see them. If their URLs work for anyone, staging becomes unmoderated file hosting until the time limit runs out.
  - Control: staged assets are served only to their uploader, through short-lived signed URLs, until they are attached to a post.

## Legal

Not legal advice; every item here needs checking against a real source before the launch gate.

- **L1 Impressum.** § 5 DDG (the Digitale-Dienste-Gesetz, which replaced the TMG's provision in 2024) requires a summonable postal address. For the operator of an anonymous imageboard this is a personal-safety question. Now a launch-gate item; look into c/o address services.
- **L2 DSA hosting duties.** As far as known, the hosting-service obligations (notice and action, statements of reasons where the poster is reachable, notifying authorities of suspected offences threatening life or safety) apply regardless of size; the micro-enterprise exemptions cover the online-platform obligations on top of them. Notice-and-action is an M1 feature; planning's launch gate should also name L2.
- **L3 CSAM.** Adopted: the delete hold never applies to CSAM, which is purged at once (planning, Moderation), since retention may itself be an offence under § 184b StGB. Still open: how to preserve evidence for law enforcement without possessing it, and what reporting duty applies. That is the question for a lawyer.
- **L4 Licences.** Wikipedia text in snapshots carries CC BY-SA attribution and share-alike; artists keep copyright of adopted images, which is why adoption is a moderated proposal.
- **L5 Archive submission.** Control: submit only linked URLs from public posts, with query strings stripped unless an adapter allows them. N7 adds the delay.

## Process

- **S1 Agent drift.** Coding agents silently break invariants: a JS dependency, an IP logged "for debugging", a template that skips escaping, an asset reference left out of the reachability view.
  - Control: the invariants below live in the repo's agent instructions and are enforced by CI tests from M0 (planning, M0).
- **S2 Scope.** Three products plus federation plus archival is breadth that agents make feel cheap. Control: milestones run strictly in sequence, and nothing past M2 starts until M1 is public and moderated in practice. More hours shorten each milestone; they do not license overlap.
- **S3 Review bottleneck.** Agents write code faster than it can be audited. Control: review effort goes to the asset pipeline, renderer escaping, auth, the fetcher and the GC sweep; other code is trusted to tests.

### Invariants

Each one is a CI test, not just a sentence.

1. No IP address, nor anything derived from one, is ever written to disk or logs.
2. Every page and action works with JS disabled; islands only enhance pages that already work.
3. Every write, deletion and file unlink goes through the single writer.
4. Every text node is escaped by construction, in static and per-request renderers alike.
5. No user-supplied bytes are served from the main origin.
6. No decoder or metadata stripper runs inside the BEAM.
7. The fetcher never connects to a non-public address.
8. Purge leaves no row, file, thumbnail, static page or reverse link referencing the content, except the mod-log entry (see G5).
9. Every column that references an asset is part of the reachability view.
10. A staged upload is served to no one but its uploader.
11. Stripping leaves no metadata outside the allowlist, and is deterministic for a given input.

Years and attributions are from memory, not looked up; treat them as approximate.
