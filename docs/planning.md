# ike — planning

Nov 9, 2026 · lux · Living version with rendered diagrams: https://claude.ai/artifact/To7LnaxLbScy19sqWyP96g · Companion: `ike/hazards.md`

## Overview

ike is one Erlang service on lemma0 that serves an imageboard, a booru and a wiki as three views over a single store of threads, assets and revisions. The first milestone is a board whose images become booru entries.

- **Name.** *ike* is toki pona for bad or negative; as a verb, to worsen. It pairs with amartia.online, from Greek *hamartia*, "missing the mark", Aristotle's tragic error in the *Poetics*.
- **Pillars.** Board: threads, read linearly or reply-threaded. Booru: curated posts over assets, with tags. Wiki: pages that are the OP of their own thread, edits as replies shown as diffs.
- **Constraints.** Static-first HTML that works as plain forms with no JS; htmx only enhances pages that already work. Login through Authelia OIDC. Text posts are anonymous without login and store nothing beyond their contents. Image posts need an account at launch, are shown as anonymous, and the upload keeps its link to that account (hazard A1).
- **Non-goals.** Danbooru API compatibility. Chat as a source of truth. IP logs. More than one node. Mnesia.
- **Companion.** `ike/hazards.md` lists what can go wrong and how each risk is closed; its invariants bind this plan.

## Primitives and data model

Everything is one of six primitives, plus external objects (see External sources); wiki edits, comments and proposals are all posts in a thread. A reference to bytes or to a post never changes meaning; a reference to a curated thing (booru post, wiki page, tag) follows its latest accepted version.

| Primitive | What it is | Identity | Mutable |
| --- | --- | --- | --- |
| Asset | Stored bytes with metadata stripped losslessly, plus extracted dimensions, MIME and perceptual hash; thumbnails are derived | SHA-256 of the stored bytes; the original upload's hash kept for matching and bans | No |
| Upload | Event: asset, time, source URL, actor. Image uploads always carry a local account. Unattached uploads are the staging area, collected after a time limit | Upload id | No |
| Actor | Anonymous, local account, remote (federated), or a board itself | Actor id | Profile only |
| Post | OP, reply, comment, wiki revision or proposal; carries text, optional asset, optional parent post. A wiki revision stores its full text; diffs are computed at render time | Global `>>N` | No; a change is a new post |
| Thread | Ordered posts, optionally attached to a booru post or wiki page; its root may be a reply promoted from another thread | Its OP's `>>N` | Gains posts |
| Booru post | Curated record over an append-only list of asset versions; upgrades append, and purge can leave gaps | `##N` | Through proposals |

Wiki pages and tags are names, not stored objects of their own: a page name resolves to the latest accepted revision post in its thread; a tag name to its aliases, implications and optional page.

A proposal is a post with a target, a base revision, a diff and a state (open, accepted, rejected). Tag suggestions, anonymous wiki edits, image upgrades, attribution fixes and BURs are all proposals, so one queue and one voting UI serve them.

### Promotion

A reply can become the root of a new thread, or seed a wiki page, without moving or renumbering it: a thread's identity is its root's `>>N`, and that root need not live in the thread.

- **Reply → thread.** Promoting `>>N` creates a thread rooted at N. N stays in place in its original thread with a "split into" note; the new thread shows "split from". Links keep working because nothing is renumbered. Prior art: topic splits in phpBB-era forums, and Discourse's "move to new topic" (Jeff Atwood, Robin Ward, Sam Saffron, 2013).
- **Reply → wiki page.** Wiki revisions form a lineage, so the page's first revision is a new post copying the reply's text, marked "derived from `>>N`" with the original attribution; anonymous stays anonymous. This needs post text to be licensed for reuse (open decision).
- **Who.** Moderators directly; anyone else through a proposal, so it rides M4's queue. Pinning a reply within its thread is a separate, simpler flag.
- **GC.** A promoted root is a strong reference; purging it leaves the new thread with a tombstone root.

### Link grammar

| Sigil | Resolves to | Stable |
| --- | --- | --- |
| `>>N` | A post, including one exact wiki revision | Fixed |
| `>>>/board/N` | A post on another board | Fixed |
| `##N` | A booru post | Follows latest asset version |
| `[[name]]` | A wiki page, or a tag with its posts | Follows latest revision |
| `{{query}}` | A booru search | Live |

## Architecture

ike is a single Erlang release behind nginx; SQLite is the only authoritative store, and every other component is derived from it or feeds it.

Diagram (text form): "SQLite holds the truth; pages and thumbnails are derived"

```
Browser (plain forms; htmx optional)  <-- login redirect -->  Authelia + LLDAP (OIDC, already on lemma0)
   |
   v
nginx (serves static pages and media from disk; passes POSTs and islands to ike)
   |
   v
[ike: one Erlang release on lemma0]
   Cowboy handlers (forms, OIDC callback, islands) --> Rate limiter (ETS, in memory only)
   Cowboy handlers --> Asset pipeline (hash, strip EXIF, thumbnails) --> Writer (gen_server, one write at a time)
   Writer --> Renderer (rebuilds pages after commit)
   GC sweeper (scheduled; deletes via writer) --> Writer
   |
   v
Asset pipeline --> Media store (files named by hash)
Writer         --> SQLite (source of truth, WAL)
Renderer       --> Static pages (HTML tree nginx serves)
```

Writes go Cowboy → asset pipeline → writer → SQLite. The renderer follows each commit and the GC sweeper sends its deletions back through the writer, so every page and thumbnail can be thrown away and rebuilt.

- **No Mnesia.** Dropped (hazard D4): two stores without a shared transaction can drift, and SQLite reads are fast on one node. ETS covers anything hotter; Mnesia returns only if measurements demand it.
- **Static and dynamic.** Thread pages and current wiki pages are files rebuilt after commit. Tag pages and search are rendered per request by Cowboy, so they work without JS. They sit behind nginx `limit_req`, caps on query terms and FTS5 prefix length, per-query timeouts, a short-lived ETS cache keyed by normalised query, and the same escaping path as the static renderer (hazard N6). Hover cards and other htmx islands only enhance a page that already works; without JS a hover card is a plain link.
- **Reverse links.** A table from every `>>N`, `##N` and `[[name]]` target to the posts that mention it, kept by the writer in the same transaction (hazard D1). Delete, purge, upgrades and renames use it to find every page to rebuild.
- **SQLite access.** Queries run on dirty schedulers with timeouts (hazard D5); pages are written to a temporary file and renamed into place (D2).
- **Identity.** Authelia stays the IdP. ike is an OIDC client like Grafana in `lemma/pulse.nix`, using PKCE, not behind forward-auth, so anonymous text posting still works.
- **Later, same release.** ejabberd for chat: mod_muc keeps only the last few messages per room in memory for joiners (`history_size`, 20 by default as far as I know); full logs exist only with mod_mam, which stays off. ActivityPub inbox and outbox are further Cowboy handlers writing through the same writer.

## Feature sets

Seven milestones, run strictly in sequence; M0 to M2 are the usable core, M6 is past the edge of feasibility and stays a direction rather than a commitment. Nothing past M2 starts until M1 is public and moderated in practice (hazard S2).

| Milestone | Features | Done when |
| --- | --- | --- |
| M0 Foundation | Nix module, ideally on its own VM; Cowboy skeleton; SQLite schema with the global post sequence, actor table and reverse-link table; single-writer gen_server; static renderer with atomic writes; Authelia OIDC client with PKCE; CSRF tokens; backups with a tested restore; the 11 hazard invariants as CI tests; a thread root column separate from each post's home thread | A logged-in POST writes a row and regenerates a page nginx serves, and a restore from backup reproduces it |
| M1 Board | Boards, locked down by default; threads, replies; anonymous text posts, image posts behind an account; sandboxed asset pipeline (libvips, lossless metadata stripping, thumbnails) with a stripping fixture corpus and a determinism test; separate media origin; hash dedup; `>>N` and `>>>/b/N`; rate limiter; hide, delete, purge, hash and account bans; mod log; DSA notice-and-action, Impressum | A stranger can post a text thread and a logged-in user an anonymous image thread, both with JS off, and abuse can be handled |
| M2 Booru | Booru posts over assets; `##N` and hover cards; tags as a join table; search, FTS5 for prefixes; asset versions and upgrades; staged uploads; GC sweeper | Every board image has a browsable, taggable booru entry, and unreferenced files get collected |
| M3 Wiki | Pages as OP of their thread; full-text revisions as replies rendered as diffs; base-revision conflict check; `[[name]]` with redirects for renamed pages; tag pages; linear or threaded view; promoting a reply to a thread or a wiki page | A page can be written, edited, discussed and linked by revision |
| M4 Proposals | One proposal queue; anonymous tag suggestions and wiki edits; BURs applied in chunks, with tag-alias redirects; voting UI; reports as proposals | An anonymous edit and a BUR both pass through the same queue |
| M5 Extras | Pools; artist / structured entries; Atom feeds and dumps; pastebin; oekaki | Each is a view over existing primitives, no new tables beyond its own |
| M6 Identity | User boards; ActivityPub; ejabberd chat in the release; user sites; NNTP, IRC, Gemini gateways | Out of scope until M4 ships |

## Dependencies

Threads are the critical path: booru posts, wiki pages and everything after them are threads with something attached.

Dependency edges (an arrow means "must exist first"):

```
Schema, IDs (actors, sequence)   --> Threads (static render)
Asset pipeline (hash, thumbnails) --> Threads
Threads      --> Booru posts (asset versions)
Threads      --> Wiki pages (OP + revisions)
Link parser (>>, ##, [[ ]]) --> Wiki pages
Booru posts  --> Tags, search (join table, FTS5)
Wiki pages   --> Proposals (one queue)
Tags, search --> BURs, votes (need accounts)
Proposals    --> BURs, votes
OIDC login (via Authelia) --accounts and actors--> Federation (user boards, AP)
```

A box can start once everything pointing into it has shipped. Federation hangs only off identity, so user boards and ActivityPub cost nothing to defer as long as the actor table exists from M0.

## Schedule

At about 10 hours a week, the usable core (M0 to M2) takes roughly 16 weeks, and M5 lands around July 2027.

| Item | Start | End | Weeks |
| --- | --- | --- | --- |
| M0 Foundation | 2026-11-16 | 2026-12-14 | 4 |
| M1 Board | 2026-12-14 | 2027-01-25 | 6 |
| Public launch gate | 2027-01-25 | 2027-01-25 | milestone |
| M2 Booru | 2027-01-25 | 2027-03-08 | 6 |
| M3 Wiki | 2027-03-08 | 2027-04-12 | 5 |
| M4 Proposals, BURs | 2027-04-12 | 2027-05-24 | 6 |
| M5 Extras | 2027-05-24 | 2027-07-05 | 6 |
| M6 Federation, chat (speculative) | 2027-07-05 | 2027-09-27 | 12 |

Estimate, not measured; the 10 h/week figure is unconfirmed, and M0 has grown since (backups, CI invariants, reverse links). The durations are the estimate; the dates only follow from them. Milestones run in sequence, since nothing past M2 starts until M1 has been moderated in public (hazard S2). The launch gate sits after M1 and also requires working backups with a settled answer for purged content in them, the host-isolation decision, an answer on the Impressum address, and confirmed DSA hosting duties (hazards D6, D7, N2, L1, L2).

## Media types

The asset primitive already covers video and interactive media: identity stays the hash of the stored bytes, and everything shown is a derived variant. What changes per type is the pipeline and, for anything that runs code, how it is sandboxed.

| Kind | Stored | Derived | Served as | Milestone |
| --- | --- | --- | --- | --- |
| Image | Original with metadata stripped losslessly | Thumbnail, sample | `<img>` | M1 |
| Video, animation | Original (WebM, MP4, GIF) remuxed without metadata | Poster frame, thumbnail, duration; transcode only when the original won't play | `<video>`, works without JS | M2 |
| Frame sequence (ugoira-style zip) | Original zip with frame timings | WebM render | `<video>` | M5 |
| Audio | Original without metadata | Waveform image, duration | `<audio>` | M5 |
| Interactive (SWF via Ruffle, HTML5 bundles) | Original | Poster frame if one can be made | Sandboxed iframe behind a "Run" click | M6 |
| SVG | Rejected | n/a | n/a | Never (hazard P5) |

- **Separate origin.** All user media, not only executable media, is served from a separate cookieless registered domain with `X-Content-Type-Options: nosniff`, a restrictive CSP, and file extensions taken from the validated type (hazard P3). A worm needs a logged-in session on the main origin; the media origin never has one.
- **Stripping, not re-encoding (hazards P4, P7).** Pixels match the upload while GPS and camera data are gone; transcoding happens only when the original won't play.
    - JPEG: EXIF orientation applied losslessly first (`jpegtran -rotate` or `-flip`, `-trim` when needed), then `jpegtran -copy none`.
    - PNG and WebP: a chunk allowlist, not a denylist. Data after `IEND` or past the RIFF length is dropped. ICC profiles are kept only when they match a known standard profile.
    - Video: explicit stream mapping (one video, one audio), `-map_metadata -1 -map_chapters -1 -fflags +bitexact`, remuxed with `-c copy`. Default stream selection could pass GPS data tracks such as GPMF.
    - Stripper versions are pinned in Nix; a bump that changes output bytes is a hash migration.
- **Processing.** libvips rather than ImageMagick (hazard P1). Every decoder and stripper runs as a separate OS process through an Erlang port, in a systemd unit with no network, seccomp filtering, a read-only filesystem except its scratch directory, and CPU, memory and time limits. A hostile file can kill a job, never the BEAM.
- **Limits.** Byte caps in nginx before ike sees an upload; dimensions and frame counts read from headers and checked before decoding (hazard P2).
- **Pipe dream.** Time anchors in the link grammar (`##N@1:23`) and comments pinned to a timestamp, as Niconico Douga (Dwango, 2006) does with overlay comments.

## Moderation

Moderation is a ladder of reversible-to-final actions, every action is itself a post in a public log, and bans target content and accounts, never anonymous people.

| Action | Effect | Reversible | Milestone |
| --- | --- | --- | --- |
| Hide | Removed from rendered pages; row and file kept | Yes | M1 |
| Delete | Gone from every view; kept for a fixed hold period for appeals or legal requests, then purged. CSAM is never held: it is purged at once (hazard L3) | Within the hold | M1 |
| Purge | Rows, bytes, thumbnails, static pages and reverse links destroyed or rebuilt; the asset hash goes on a blocklist | No | M1 |
| Hash ban | Rejects any future upload of that hash at the asset pipeline | Yes | M1 |
| Account ban | Suspends a local account; LLDAP disable or an ike-side flag | Yes | M1 |
| Board lockdown | Accepts posts from logged-in accounts only; the default for new boards (hazard A4) | Yes | M1 |
| Report | A proposal targeting a post with "hide" as its diff; janitors work the same queue | n/a | M4 |

- **Roles.** Admin, moderator, janitor, from LLDAP groups via the OIDC `groups` claim, the way `pulse.nix` already gates Grafana, bound to a short-lived session so removals take effect quickly (hazard I5). Board-owner moderators arrive with user boards in M6.
- **Mod log.** Each action is a post in a `/mod/` thread: who acted (role, not necessarily name), target `>>N`, reason. Hide, delete and purge leave the same tombstone wording (hazard G5). A purged post's entry keeps the reason, never the content; whether it shows the hash publicly is open.
- **Anonymous text abuse.** An in-memory rate limiter keyed per IPv4 address or IPv6 /64, trusting forwarding headers only from nginx, with its salt never leaving memory (hazards N3 to N5); per-board cooldowns; a JS-free captcha if needed; lockdown.
- **Image uploads.** They need an account, so whoever uploads illegal material can be banned. The upload-to-account link is therefore stored; whether in plaintext or encrypted to a key kept offline is open (hazard I4), and the UI says which applies.
- **Near-duplicates.** Perceptual-hash matches flag an upload into the moderation queue and never ban automatically (hazard A3).
- **Illegal content.** Purge is immediate and complete. Reporting duties, the Impressum and the DSA are hazards L1 to L3; none of this is legal advice.

## Garbage collection and references

ike collects garbage the way the Nix store does: posts and live staged uploads are roots, strong references keep things alive, and a scheduled sweep deletes whatever is unreachable after a grace period. References that "keep updated" are resolved at render time, never rewritten, because post text is immutable.

- **Strong references** keep their target alive: post → asset, booru post → its asset versions, staged upload → asset, snapshot → mementos, thread → a promoted root.
- **Weak references** never do: `>>N`, `##N` and `[[name]]` in text. A missing target renders as a tombstone.
- **Following.** An upgrade appends an asset version, and `##N` follows it. Renamed pages, aliased tags and booru posts merged as duplicates become rows in a redirect table that `[[name]]` and `##N` resolve through.
- **Redirects (hazard G2).** Each redirect stores its terminal target. A redirect that would create a cycle is rejected, and the resolver follows a bounded number of hops. An existing page beats a redirect; claiming a redirected name is a proposal.
- **Re-rendering (hazard G4).** Static pages link to stable names (`/w/name`, `/p/N`) resolved at request time, so most changes need no re-render. A page is re-rendered only when what it displays changes (tombstones, inlined quotes), through a deduplicated, rate-limited queue behind ordinary commits.
- **Board posts pin.** A board post keeps showing the asset as posted, with an "upgraded → ##N" note, so the old version stays alive through it (open decision).

| Collected | When |
| --- | --- |
| Staged uploads past their time limit | After the time limit |
| Asset files with no strong references | After a grace period, so an in-flight post never loses its file |
| Thumbnails and samples | Anytime; regenerable |
| Static pages of deleted threads | At deletion |
| External snapshots no post links to | Per the open decision on snapshots |
| Tags with no posts, page or aliases | During the sweep |
| Deleted content past its hold | Purged |

- **Reachability (hazard G6).** One SQL view defines it; a schema test fails if any asset-referencing column is missing from that view.
- **Sweep (hazard G1).** A scheduled job finds unreachable candidates, and the writer re-checks reachability inside each delete transaction. The grace period runs from when the last reference was removed. The writer performs both unlinks (after commit) and the final rename of new asset files. Each sweep has a deletion cap that aborts the run; deleted files go to a quarantine directory and are unlinked only after a second grace period.
- **Purge (hazard G3).** Targets the asset by stored hash and removes every strong reference to it in one transaction; referencing posts keep their text and show a tombstone in place of the file. The stored hash and every original hash seen for it are blocklisted. Collected and purged files survive in backups until the retention window ends (hazard D7).
- **Staging (hazard G7).** Staged uploads are served only to their uploader, through short-lived signed URLs, until attached.
- **Prior art.** Mark-and-sweep (John McCarthy, Lisp, 1960) and reference counting (George Collins, 1960); the Nix store's GC roots (Eelco Dolstra, from 2003); `git gc` and its prune grace period (Linus Torvalds, 2005).

## External sources

ike treats other sites as read-only peers that never agreed to federate: an external object is a URI plus an adapter plus revisioned snapshots, fetched on demand and never mirrored wholesale. It replaces the dead-link "External links" list with references that keep working after the source changes or disappears.

- **Primitive.** External object = URI, adapter name, and snapshots (fetch time, content hash, extracted fields). Each snapshot is a post in the object's thread, so `>>N` pins exactly what was seen, and `[[name]]` can point at the object to follow its latest snapshot.
- **Fetching.** Lazy and asynchronous: a page renders with the last snapshot and a refresh is queued. The renderer never blocks on a remote site. One fetch queue with per-host rate limits and an honest User-Agent; the fetcher never connects to a non-public address (hazard N1). Only links that survive a delay with no moderation action, or links in curated objects (tags, wiki pages, booru sources), are fetched and archived; a snapshot never downloads a page's linked images (hazard N7).
- **Linking.** A tag or wiki page can name its external counterparts: a Danbooru tag, a Wikidata item, a Wikipedia article, an artist's accounts. Hover cards draw from the snapshot.
- **Adopting.** An external image becomes local only by an upload proposal carrying its source URL. That is the one path from vendoring to hosting.
- **Adapters, easiest first.** Danbooru JSON API (posts, tags, wiki, artists); MediaWiki API for Wikipedia; Wikidata entity JSON; generic Open Graph and oEmbed as fallback; Pixiv and X last, since they fight scraping. Consuming Danbooru's API is unrelated to the non-goal of implementing it.
- **Licences.** Quoting Wikipedia text in a snapshot carries CC BY-SA attribution and share-alike. Images on art sites stay their artists' copyright, which is why adoption is a deliberate, moderated act.
- **Prior art.** Transclusion (Ted Nelson, Project Xanadu, coined around 1980); Pingback and TrackBack (2002); oEmbed (2008, Cal Henderson and others); Wikidata's external identifiers (2012, Denny Vrandečić); Danbooru's per-site source strategies; Webmention (W3C 2017, Aaron Parecki), the consenting version of the same idea.
- **Milestone.** Read-only snapshots and the Danbooru adapter after M2, where they help seed tags; the rest in M5.

### Archival

Every external object ike snapshots also gets submitted to several third-party archives, so ike records where captures live instead of archiving the web itself. Redundancy is the point: any one archive can be down, blocked or gone.

- **Look before saving.** Ask the Memento protocol (RFC 7089, 2013, Herbert Van de Sompel et al.) for existing captures across archives first; submit only when none is recent enough.
- **Targets.** Wayback Machine (Save Page Now API); archive.today (no official API, CAPTCHAs, anonymous operator); Ghostarchive; Megalodon for Japanese sites. Each is an adapter with its own queue, retries and backoff. Only linked URLs from public posts are submitted, query strings stripped unless an adapter allows them (hazard L5).
- **Record.** Each capture is stored as a memento: archive, capture URL, capture time. It hangs off the snapshot post, so a hover card can fall back to an archived copy when the source is dead.
- **Last resort.** ike's own snapshot keeps only extracted fields and a content hash, never the page. A local ArchiveBox (Nick Sweeting, 2017) limited to pages some post actually links to is the fallback if every archive refuses.
- **Prior art.** Wikipedia's InternetArchiveBot (Cyberpower678, mid-2010s) rewrites dead citations to archived copies, which is this same loop run on references.

## Open decisions

The first nine block M0, M1 or the launch gate; the rest can wait for the milestone that needs them. Hazards still waiting on a decision are tracked in `ike/hazards.md`.

- [ ] Hours per week: the schedule assumes about 10
- [ ] Impressum address (hazard L1)
- [ ] Questions for a lawyer: which DSA hosting duties apply (L2); how to preserve CSAM evidence for law enforcement without possessing it, and any reporting duty (L3)
- [ ] Upload-to-account link: plaintext, or encrypted to a key kept offline (I4)
- [ ] Separate media origin: which registered domain
- [ ] Backup tool and retention window, or crypto-shredding (a per-asset key destroyed on purge) instead of a short window (D6, D7)
- [ ] ike on its own VM, or hardened on lemma0 (N2)
- [ ] Purge entries in the public mod log: show hashes, or a reason category only with hashes admin-only (G5)
- [ ] Does every board image become a booru post at once, or stay a staged upload until someone tags it?
- [ ] Retention of deleted content, and the takedown flow under the DSA
- [ ] Hold period between delete and purge
- [ ] Size and duration caps per media type
- [ ] Licence for post text, which promoting a reply to a wiki page depends on
- [ ] Who may promote: moderators only, or anyone through a proposal
- [ ] Board posts pin the asset as posted, or follow upgrades
- [ ] GC grace periods (after the last reference, in quarantine) and staging time limit
- [ ] Short reference for assets (a hash-prefix sigil), or none
- [ ] Reply-threaded view: is a reply's parent its first `>>N`, or chosen explicitly?
- [ ] Wiki conflicts on the same base revision: reject the later edit, or attempt a three-way merge
- [ ] Do rejected proposals stay visible in the thread?
- [ ] Rate-limiter salt rotation period
- [ ] External snapshots: keep every one, or only those a post links to
- [ ] Fetch delay for links in anonymous posts, before any adapter (N7)
- [ ] Which archives to submit to by default, and whether archive.today belongs on the list
- [ ] External known-hash lists: whether any are accessible (A3)
- [ ] Executable media isolation before M6: `Content-Security-Policy: sandbox` with an `<iframe sandbox>` lacking `allow-same-origin`, or one origin per bundle (P8)
- [ ] How anonymous posts federate: as the board's group actor, or not at all

## Prior art

Oldest first, so each idea sits after what it built on. Years and attributions are from memory, not looked up; treat them as approximate.

| Year | Project | Author | What ike takes from it |
| --- | --- | --- | --- |
| 1960 | Mark-and-sweep, reference counting | John McCarthy; George Collins | The GC model |
| 1980 | Usenet | Tom Truscott, Jim Ellis | The ur-board; an NNTP gateway later |
| 1995 | WikiWikiWeb | Ward Cunningham | Free-standing pages, not every page a tag |
| ~1996 | Mnesia | Ericsson: Claes Wikström, Håkan Mattsson, Hans Nilsson | Considered and dropped |
| 1999 | 2channel | Hiroyuki Nishimura | Text-only threads, anonymous by default |
| 2001 | Futaba Channel | Futaba admins | First imageboard |
| 2001 | Edge Side Includes | Akamai, Oracle et al. | Static shell with dynamic fragments |
| 2002 | MediaWiki | Magnus Manske; rewritten by Lee Daniel Crocker | Talk pages beside articles |
| 2003 | 4chan | Christopher Poole | Board conventions, `>>N` |
| 2003 | Nix | Eelco Dolstra | GC roots over a content-addressed store |
| ~2004 | Wakaba, Kareha | WAHa.06x36 | Regenerate static HTML per post |
| 2005 | Danbooru | Albert | Tags, BURs voted in forum topics, DText links |
| 2005 | Git | Linus Torvalds | Content addressing, gc with a prune grace period |
| 2007 | VNDB | Yoran Heling | Structured entries where every edit is a discussed revision |
| 2011 | Federated Wiki | Ward Cunningham | A page as a fold over its journal of edits |
| 2013 | intercooler.js, later htmx (2020) | Carson Gross | Server-rendered fragments over forms |
| 2013 | Neocities | Kyle Drake | User sites |
| 2018 | ActivityPub (W3C Rec.) | Christine Lemmer-Webber, Jessica Tallon et al. | Federation of user boards |
| 2019 | Lemmy | Dessalines, Nutomic | Group actors relaying posts |
| 2019–20 | Islands architecture | Katie Sylor-Miller, Jason Miller | Hover cards as enhancement |
| 2021 | FChannel | unknown | A federated imageboard |
| ~2022 | Khepri | Jean-Sébastien Pédron, RabbitMQ | Erlang-native replicated store, if ever needed |
