# ike — decisions

Choices made where the docs left the implementation open, each with why.
Decisions lux made in answer to `questions.md` are marked (lux).

## Nix

- **`default.nix` is the entry, and there is no flake** (lux, 2026-11-14;
  was C5). fog has none, and a wrapper nobody evaluates only rots.
- **`pins.json` is the only pin, in fog's format, moved by `nix/pin`**
  (lux, 2026-11-14).
- **nixpkgs is pinned to the revision fog pins** (`1d060086`), with the
  same url, hash and store name, so lemma0 builds ike from the nixpkgs it
  already has.
- **The module's package defaults to ike's own pin, not the system's
  nixpkgs.** The toolchain that CI tested is the one that runs, and from M1
  the strippers' output bytes name assets (P7): a host's nixpkgs bump must
  not change them unseen. *Pragmatic cost:* a second nixpkgs evaluation and,
  when the revisions differ, a larger closure. `services.ike.package`
  overrides it.
- **Hex packages are fetched by hash from `nix/hex.json`,** which `nix/lock`
  writes from `rebar.lock`, and handed to rebar3 as `_checkouts`. No rebar3
  plugin, and no fixed-output derivation whose hash has to be guessed.
- **The eqWAlizer check patches ELP's binary.** ELP unpacks eqWAlizer, a
  native image that wants `/lib64`'s loader, at run time; no sandbox has
  that loader. The check overwrites the loader's path inside ELP with
  `/build/ld.so` and puts a loader there. *A hack,* confined to
  `nix/package.nix`, x86_64-linux only; it asserts the path occurs exactly
  once, so an ELP bump that changes this fails loudly. The alternative was
  running eqWAlizer outside the checks.
- **The module is booted in a NixOS VM as a check** (`nix/test.nix`). This
  is a test of the unit, not a way to deploy: the hardening and the start
  command exist only in the module, and nothing else exercises them. Its
  first run found that the unit never started while the other three checks
  were green. It is the slow check (minutes on theorem); it matters when
  `nix/` or the release settings change, and CI runs it always.
- **Actions are pinned by major tag** (`actions/checkout@v4`,
  `cachix/install-nix-action@v31`), not by commit. *Pragmatic;* pinning by
  hash is better once someone reads the diffs on bumps.

## Deployment

- **Caddy is the web server in front, alone** (lux, 2026-11-14; was C1).
  lemma0 already runs it on 80 and 443, so ike adds no second HTTP server:
  `file_server` for the page and media directories, `reverse_proxy` for
  the rest, `request_body max_size` for the body limit. Caddy's rate
  limiting is a plugin and is not used; ike's own limiter (M1) is the one
  that counts. planning.md still says nginx; that text is lux's to change.
- **Backups are snapshots into a directory** (lux, 2026-11-14; was Q8),
  taken through SQLite's backup API. Shipping them off the host is fog's.
- **On lemma0, as a unit, without a VM of its own** (lux, 2026-11-14;
  hazard N2, was Q9). The unit's sandboxing is the boundary. Worth another
  look at M1, when decoders and strippers start running on what strangers
  upload.

## Erlang

- **OTP 29,** current stable in the pinned nixpkgs (29.1.2).
- **One node, never distributed.** No node name, no cookie, epmd off:
  planning rules out more than one node, and a listening distribution port
  is attack surface for nothing. The unit stops with SIGTERM, which the
  BEAM turns into `init:stop/0`.
- **relx's plain start script, not the extended one.** The extended script
  refuses to start a node without a name, and its `stop`, `remote_console`
  and `rpc` all need distribution. The plain one passes its arguments to
  `erl`, so the unit runs `ike -noinput -config <file>`, and that file's
  keys override the release's `sys.config`. *Cost:* no remote shell into a
  running node. The script splits arguments with `printf '\x1f'`, which
  dash does not understand; in the store its shebang is bash.
- **PropEr is a default-profile dependency,** because `rebar.lock` covers
  no other profile and the lock is what Nix fetches from. The release
  includes only what `ike.app.src` names, so it stays out. *Pragmatic.*
- **Properties run inside Common Test suites** (`proper:quickcheck/2`),
  which saves the rebar3_proper plugin.
- **Tests are Common Test suites that start the application and then use
  only HTTP, the filesystem and the database.** Black-box in what they
  touch; they share a VM with ike for speed. The NixOS VM test
  (`nix/test.nix`) is the fully separate harness, for what needs Caddy or
  a restore.
- **eqWAlizer runs over every module under `src`,** not only the typed
  core: wider than asked, and cheap while there is little code. Narrow it
  to a list if non-core code ever needs `dynamic()`.
- **"Strict mode" is not a switch in this ELP** (2026-08-10): no
  setting that turns gradual typing off shows up in its help, its
  configuration reference or its binary. What is enforced is zero eqWAlizer
  errors. Planned for step 3: the core modules may not mention `dynamic()`,
  `eqwalizer:fixme` or `eqwalizer:ignore`, checked by a test. If lux knows
  the switch that was meant, it goes in then.
- **No `maybe` expressions in typed modules.** This eqWAlizer does not
  narrow what `?=` lets through, so every one is a type error; nested
  `case` it is. Likewise `lists:sort` and `lists:reverse` come back as
  `[term()]` here, so `ike_migrate` avoids them.
- **Paths are binaries** inside ike (`data_dir`), turned into strings only
  at esqlite's door: a guard can tell eqWAlizer a value is a binary, not
  that a list is a string.
- **Crash dumps are off in the unit** (`ERL_CRASH_DUMP_BYTES=0`): a dump
  holds whatever was in memory, which from M1 includes the rate limiter's
  salt and addresses (N5, invariant 1).
- **`/health`** exists so that tests and the unit have something to ask.
- **Listening on loopback, port 8970** by default; a Unix socket (N3) can
  replace it when the rate limiter arrives.

## Login

- **OIDC against Authelia from the start, not LDAP** (lux left it to
  whichever is quicker, 2026-11-14). Not slower to build: authorization
  code with PKCE needs only `httpc`, `json` and `crypto`, all in OTP, and a
  mock IdP for the tests is one Cowboy handler. LDAP would have ike take
  passwords itself, which wants its own brute-force limit, goes around
  Authelia's second factor, and names users by DN, so every actor would
  need rewriting when SSO came. `actor (issuer, subject)` is already OIDC's
  key.

## Licence

- **lux's own notice, in `LICENSE`** (lux, 2026-11-14; was Q6).

## Schema

- **Migrations are numbered SQL files in `priv/migrations`,** applied at
  application start, each in one transaction, before anything else runs. A
  `migration` table keeps each file's SHA-256: an applied file that changed,
  or a database newer than the release, refuses to start. There is no down
  migration; going back is a restore.
- **Connection settings** (`ike_db`): WAL, `synchronous = FULL`, foreign
  keys on, a 5 s busy timeout, `trusted_schema` off, and `secure_delete`
  on, so that what purge deletes is overwritten in the file and not left
  in free pages.
- **Every table is `STRICT`.**
- **`post.id` is `AUTOINCREMENT`:** a `>>N` is never handed out twice, not
  even after its row is gone.
- **A post carries its time** (lux, 2026-11-14; was Q1): `post.time`,
  whole seconds since the epoch, set by the writer and never taken from
  the client. Migration 0001 was changed in place, which is allowed only
  because no database has ever been made from it outside the tests.
- **Every post has an actor, and anonymous is an actor** (lux, 2026-11-14;
  was Q2): one shared row, id 1.
- **One global post sequence** (lux, 2026-11-14; was C4): ikooru spans the
  whole of chike, and there are no boorus per board.
- **What belongs to an upload is stored with the upload, not the asset**
  (lux, 2026-11-15; was C3): the hash of the bytes as sent, and whatever
  else describes that one act of uploading, the way an artist's commentary
  belongs to a posting and not to the work. The asset is only the stored
  bytes, so several uploads share one asset and each keeps its own
  original hash. No table yet: uploads arrive with M1.
- **A thread has no id of its own; its key is its root's post number.** An
  OP's home thread is its own number, so the two foreign keys between
  `post` and `thread` are deferred to the end of the transaction.
- **Actor and link are sums stored flat.** `actor.kind` is an enum with
  nullable `issuer` and `subject`; `link` has three nullable target
  columns. *Pragmatic:* SQLite has no sum types, and a table per variant
  costs a join on every read. `CHECK` constraints tie each kind to its
  columns and each link to exactly one target, and tests try to break
  them.
- **A local actor is an issuer and a subject,** the pair OIDC guarantees
  unique. No name, e-mail or group is stored.
- **Link targets are not foreign keys.** They are weak references: a
  target may not exist yet or any more. The source is one, and cascades.
- **`asset.hash` is a 32-byte blob,** not hex text.
- **The reachability view labels each row `'table.column'`.** The test for
  invariant 9 takes the columns from the foreign keys and wants each label
  in the view. *Limit:* it plants a row only for `post.asset`; a new asset
  column has to add its own to the test, which fails until then.
- **esqlite carries its own SQLite** (3.50.4), pinned by esqlite's Hex
  hash, and builds it with the `pc` rebar3 plugin from nixpkgs. `pc` is a
  build-time dependency esqlite brings with it.
- **Timeouts (D5):** every esqlite call runs on a dirty I/O scheduler, the
  busy timeout bounds waiting for a lock, and `ike_db:q` arms a timer that
  calls `sqlite3_interrupt` after 5 s. *Limit:* a timer that fires just as
  its query returns can interrupt the next one on that connection, which
  then fails like any timed-out query. `exec` is not bounded: it runs
  migrations and `COMMIT`.

## Writer

- **The write capability is the connection's type.** `ike_db` hands out
  `reader()` and `writer()`, both opaque; `exec` and `transaction` take
  only a writer, and a reader has `PRAGMA query_only` set, so SQLite
  refuses what the types missed. Only `ike_writer` opens a writer.
- **The writer migrates.** Bringing the schema up to date is a write, so
  it happens in the writer's `init`, and the supervisor starts everything
  else after it (`rest_for_one`).
- **One message, one transaction.** Callers wait up to 15 s; giving up
  does not undo a commit.
- **`ike_id`: post and actor numbers are opaque and tagged,** so one
  cannot be passed for the other or made from a bare integer elsewhere.
  No booru id yet: nothing in M0 has one.
- **A post's text** is UTF-8, at most 16 KiB, not empty, with no control
  characters but newline and tab. The writer checks it, whoever asks.
- **The writer does not parse links yet.** The reverse-link table is in
  the schema and nothing fills it: the link grammar is M1's. It will be
  filled in the same transaction as the post (D1).


## Renderer

- **Pages are files, written whole and renamed into place** (D2), by
  `ike_render`: `t/N.html` per thread and `index.html`. Every page is
  rendered again at start, so the pages are a cache and a restore need
  not carry them.
- **HTML is a tree** (`ike_html`) with a closed set of tag and attribute
  names; text becomes bytes in one place, escaped there (invariant 4).
  Per-request pages (forms, refusals) go through the same tree.
- **The renderer follows commits.** The writer tells it which thread
  changed after each commit; it keeps a set of dirty threads and renders
  one per turn. A handler that redirects to a page waits for the set to
  drain first.
- **The renderer writes its own files.** Invariant 3 is read as: the
  database, and every deletion and unlink, belong to the writer; pages
  are derived and only ever replaced. lux (was Q9): fine, so long as it
  stays linearly auditable. The test lists exactly who changes files.
- **Nothing shows who posted, yet.** A post made by an account stores
  that account's actor and displays nothing of it. lux (was Q10): the
  account's name goes where imageboards put the anonymous name, linking
  to `/user/<nick>`; that page looks like a board whose pinned post is
  the user's bio, on each of the three views. Not built: it needs a
  name kept per actor and the user boards, see `questions.md`, Q14.
- **Cowboy serves the pages too**, from the same files, so that ike works
  without a web server in front (development, tests). Caddy answers
  those paths first where it is there.
- **Pages live in `/var/cache/ike`** under the module, apart from the
  state, so that Caddy can be let into them and nothing else. ike runs as
  a static user `ike`, not `DynamicUser`, whose directories no other
  user can reach; Caddy's user joins the group.
- **Caddy writes no access log** for ike's host (`logFormat = null`):
  an access log is a list of addresses (invariant 1).

## Requests

- **The first stream handler forgets the peer** (`ike_http_anon`): the
  address is overwritten and the forwarding headers dropped before any
  handler, or any crash report quoting a request, can see them
  (invariant 1). M1's rate limiter has to sit there, ahead of the
  forgetting, and keep what it derives in memory only.
- **The same handler gives every answer the common headers**, including
  the ones Cowboy sends by itself. *Simplification:* two concerns in one
  module, because both have to be first in line.
- **Only urlencoded forms are read.** Anything else, multipart first of
  all, is refused with 415 before its body is read (A1, invariant 5).
  A form is at most 64 KiB, in Cowboy and in Caddy.

## Login, as built

- **OTP only:** `httpc`, `json`, `crypto`, `public_key`. No JOSE or OIDC
  library was added.
- **RS256 and nothing else.** The token's header picks a key by `kid`
  and has no say in the algorithm. Authelia signs with RS256 by default;
  ES256 would be a second, equally small verifier.
- **Checked:** state (single use, ten minutes), a cookie binding the
  callback to the browser that started the login, PKCE with S256, the
  signature against the issuer's JWKS, `iss`, `aud` (with `azp` when
  there are several), `nonce`, `exp` and `iat` with a minute's leeway.
- **Kept of a person:** issuer and subject, as an actor. No name, no
  email, no token. The `groups` claim (I5) is not read yet: nothing in
  M0 has roles.
- **Keys are cached for an hour** and asked for again, at most once a
  minute, when a token names one that is not known.
- **Both kinds of client work:** with a secret file the token request
  authenticates with it, without one it relies on PKCE (Q7).
- **Sessions are rows** (lux, was Q12: they should outlive a restart),
  eight hours, with a CSRF token each. The writer writes and deletes
  them; they are read once at start into a table in memory, which
  answers every request. A row is named by the SHA-256 of what the
  cookie holds, so reading the database gives nobody a session. Chosen
  over signed cookies, which need a key kept somewhere and cannot be
  ended by logging out.
- **Snapshots are taken without the session rows.** A backup does not
  say who was logged in when, and a restore revives no session.
  *Simplification:* the live database does say so for eight hours, and
  `ike_db` knows the one table's name to scrub it from the copy.
- **Half-finished logins stay in memory.** A restart in the middle of a
  login means starting it again.
- **Cookies** are `__Host-` prefixed, `Secure`, `HttpOnly`,
  `SameSite=Lax` (I2).
- **Every way a login can fail gives the same answer**, a 400 that says
  to start again.
- **Only accounts post in M0.** Anonymous posting needs the rate limiter
  and moderation, which are M1.

## Backups

- **Snapshots through SQLite's backup API** (D6), taken by the writer
  from its own connection, checked with `integrity_check`, written under
  a temporary name and renamed. *Simplification:* the writer does not
  write while it copies; at M0's sizes that is milliseconds. Litestream
  (Ben Johnson, 2021) stays the alternative should that stop being true.
- **`<data_dir>/backups/<UTC time>.db`**, one a day and seven kept by
  default, both options. Seven is a stand-in for the retention window,
  which is lux's (Q8, D7); lux finds it generous but leaves it for now.
  Each snapshot is a whole copy of the database, sharing nothing with
  the others or with it. Old ones are unlinked by the writer.
- **A restart takes no snapshot of its own** unless the newest is older
  than the interval, so that a crash loop cannot push the good ones out.
- **A restore is a copy:** stop, put a snapshot where `ike.db` was, start.
  Pages are rendered again from it. `ike_backup_SUITE` does exactly this
  and compares rows and page bytes.
- **Taking snapshots off the host is fog's.**

## Invariant tests

- **`ike_invariant_SUITE` has one case per invariant**, in hazards.md's
  order. 1 to 5 and 9 test what M0 has. 6, 7, 8, 10 and 11 speak of
  things M0 lacks (decoder, fetcher, purge, staging, stripper); their
  cases are *tripwires*: they assert the thing is absent, fail when it
  arrives, and are to be replaced by the real test in the same change.
  They prove nothing about the thing itself. lux (was Q11): that will do
  for M0.
- **Structure is read from the compiled modules** with xref: who calls
  SQLite, who opens a writer, who changes files, who connects out. The
  lists are exact, so a new such place fails until it is listed.
- **Routes and tables are listed exactly** for the same reason.
- **Invariant 1's log test cannot provoke a crash report** from outside.
  It checks that nothing is logged for ordinary and refused requests,
  and structurally that the forgetting handler is first and nothing asks
  for a peer.

## Names

- **The repository is public** (lux, was Q5), so fog can pin it without
  credentials.
- **One host, three paths** (lux, was Q13): `ike.amartia.online/board`,
  `/booru` and `/wiki`, so one login covers all three. Nothing in a
  page or a redirect names the host, which leaves a view free to move
  to a host of its own later.
- **Authelia answers at `auth.amartia.online`**, which is the issuer.
- **A confidential client** (was Q7; lux left it to phi). ike is a
  server that can keep a secret, the secret costs one `LoadCredential`,
  and with it a stolen authorization code is useless even to someone
  who also has the verifier. PKCE stays on. The public kind keeps
  working, should that change. Client id `ike`.

## Boards (M1)

- **Which boards exist is configuration** (`services.ike.boards`, name
  to title), brought into the database by the writer at start. Taking
  one out of the configuration leaves it and its threads alone.
  *Simplification:* no page creates a board; M6's user boards will need
  one.
- **Whether a board is locked is a row**, since a moderator changes it.
  A new board is locked (A4).
- **A board's name** is one to sixteen of a to z and digits, checked by
  the router, the configuration and the table.
- **Paths:** `/board` lists boards, `/board/b` a board's threads,
  `/board/b/12` a thread, with `/new` and `/reply` beneath. Page files
  are the path plus `.html`, so Caddy needs no rule per kind of page.
  The file name is put together from what the router bound, never from
  the path as sent.
- **A thread has at most one board**, a nullable column: planning.md
  lets a thread hang off a booru post or a wiki page instead. A thread
  on no board has no page. A thread is reached through its own board
  only.
- **A board is not an actor yet.** The schema's `board` kind of actor
  waits for federation.
- **`>>N` stays global**; a post's number says nothing of its board.

## Links (M1)

- **`>>N` and `>>>/board/N`**, as planning.md's grammar has them. A
  number is written as ike writes one: no sign, no leading zero, at
  most 18 digits. `>>>/b/N` is a link only if N is on `b`; since
  numbers are global it says nothing `>>N` does not, and is kept as
  typed.
- **One reading, in `ike_text`,** used by the writer for the reverse
  links and by the view for the markup, so the two cannot disagree
  about what is a link (hazard D1). The rows go in with the post, in
  its transaction.
- **A link goes to `/p/N`,** answered per request with a redirect to
  the thread's page (planning.md: stable names resolved at request
  time, hazard G4). A page is made again only when what it shows
  changes: a target appearing, or someone new pointing at one of its
  posts.
- **`ike_reader`:** one read-only connection behind one process, for
  what is answered per request. *A simplification:* one, not a pool;
  lookups queue behind each other.
- **A link to nothing** is a `span` of class `gone` holding what was
  typed, the same whether the target is hidden, purged, was never
  there or is yet to come (hazard G5). A target that appears later
  turns it into a link: the reverse-link table says which pages to
  make again.
- **Who points at a post** is listed under it, oldest first.
- **At most 32 links in a post;** what follows is only text. Each is a
  row and possibly a page to render. *A number picked, not measured.*
- **The renderer reads targets from `link`, not from the text.** A
  post written before `link` was filled would show its links as gone;
  there is none, since nothing was deployed.

## Uploads (M1, ahead of the code)

- **Original hashes are copied out** (lux, was C3) when an upload is
  collected or its asset purged: a blocklist of hashes outlives both,
  so that a re-upload of purged content is refused before it is
  stored. Upload rows themselves need not live as long as the asset.

## Names (M1)

- **A nick is the provider's `preferred_username`** (lux, was Q14), for
  now. Read at every login and kept in `actor.name`, the one column of
  an actor that changes; a rename marks every thread the account signed
  in for rendering again, since the name is the account's and not the
  post's.
- **Only from the id token.** *A simplification:* the userinfo endpoint
  would be the surer place for a `profile` claim, and is not asked, to
  keep ike at two requests to the provider per login. A provider that
  leaves the claim out of the id token gives nobody a name
  (deploying.md says how Authelia is told to put it in).
- **A nick is 1 to 32 of letters, digits, `_`, `-` and `.`**, not
  ending in a dot (so never `.` or `..`). Anything else is no name
  rather than a mangled one, and the login goes through all the same.
  The limit is there because the nick is to stand in `/user/<nick>`.
  *A simplification:* ASCII only; names in other scripts wait for
  someone to have one.
- **An account may post without it** (lux), and does unless it ticks
  "post as". An unsigned post is written for the anonymous actor, not
  for the account: nothing in the database ties the two. Hiding the
  name at render while keeping the actor would have been a link of the
  kind I4 is about, made without that decision (Q16).
- **What stands in the name's place** is `anonymous_names`
  (`services.ike.anonymousNames`), `anon` alone by default. From a
  longer list a post takes the name at its id modulo the length:
  stable across renders, changed for old posts if the list changes
  length. *A simplification:* not stored per post.
- **No link on the name yet.** It goes to `/user/<nick>` once user
  boards exist (Q14).
- **Two accounts can carry one nick** if two issuers, or one careless
  one, say so. With a single issuer that is the provider's to prevent;
  it wants a unique index before a second issuer or `/user/<nick>`.

## Posting without an account (M1)

- **Nobody posts where a board is not locked.** Boards are still made
  locked, and nothing in ike unlocks one before there are moderators
  (step 5); the tests set `board.locked` in the database by hand, as
  an operator could.
- **The form is tied to the site by a cookie, not a session.** A
  browser without an account gets `__Host-ike-form`: 32 random bytes,
  Secure, HttpOnly, SameSite=Strict, no expiry, and the same value in
  the form. A post is taken when the two match. ike keeps none of
  them, so they name nobody and tie no two posts together on the
  server (hazard I2); another site can neither read the cookie nor
  set one under `__Host-`.
- **The limiter counts in memory only** (planning.md, hazards N3 to
  N5). An address, or for IPv6 its network, is hashed with HMAC-SHA256
  under a random key and counted in an ETS table; key and counts are
  thrown away every `salt_seconds`, and with the process. Nothing of
  it is logged, written, or sent in a message. This reads invariant 1
  as it is worded ("written to disk or logs"), not as widely as
  phi.md's "log or store": Q18.
- **Counted at the door.** `ike_http_anon` charges every POST before
  it forgets the peer, and answers 429 itself to one that is over and
  has no session. Whatever goes wrong while counting becomes that
  answer and is reported nowhere, since a report would quote the
  address. No handler ever holds an address or a hash of one.
- **Every POST counts,** refused or not, with an account or without;
  only who has a session is let through when over. An account can be
  banned, and nobody cannot.
- **`X-Forwarded-For` is believed from `proxies` only,** and then its
  last entry: the one the proxy wrote (N3). The module names the
  loopback when it sets up Caddy, whose default is to overwrite what
  a client sent. A proxy that says nothing readable has everyone
  behind it counted as one.
- **IPv6 by /64,** or /56 or /48 by configuration (N4). IPv4, and
  IPv4 written as IPv6, by the address.
- **A pace for each board** (A2): posts by nobody on one board, from
  anywhere, are counted too, and only those that would have gone
  through. Configuration for now; a moderator's to set in step 5.
- *Simplifications:* fixed windows, not a sliding one or a token
  bucket, so a burst across a window's edge gets twice the count.
  A new key forgets every count rather than carrying them over. At
  200000 rows everyone without an account waits, instead of the
  oldest rows being dropped. The numbers (4 a minute an address, 10 a
  minute a board, an hour a key) are picked, not measured.

## Roles and moderation (M1)

- **Roles from the `groups` claim,** read at login and kept with the
  session (row and memory), so a role lives exactly as long as the
  session (I5): a change at the provider takes effect at next login.
  Group names are configuration (`roles`; defaults `ike-admin`,
  `ike-moderator`, `ike-janitor`); the highest one held wins.
- **Who may do what** (`ike_role:may/2`): janitor hides and unhides;
  moderator does everything but purge; admin everything; ike itself
  only purges, when a hold ends. Planning names the rungs, not this
  table: Q20.
- **States on the post row:** 0 shown, 1 hidden, 2 deleted with a
  `purge_at`; purge removes the rows. The view `shown` is a post that
  is shown on a thread whose first post is shown, and every page, link
  and `/p/N` reads through it. Hidden, deleted and purged look the
  same from outside (G5): gone from pages, links to them `gone`, 404.
  A first post that goes takes its thread's page with it.
- **One writer call, one transaction:** the log entry and the change
  are committed together or not at all. After the commit the writer
  asks the renderer to `settle` the thread (so no render read before
  the commit lands after the unlink), unlinks the thread's page, marks
  the pages around it, and after a purge checkpoints the WAL with
  TRUNCATE. At start it unlinks any thread page no shown thread stands
  behind, which is what a stop between commit and unlink leaves.
  The renderer still unlinks nothing (invariant 3).
- **The log is a board,** `mod`, flagged `log`, taking no posts from
  anyone and not moderatable. One thread per UTC month (`2026-11`),
  each action a reply as nobody whose text is `<kind> >>N` (or `ban,
  for >>N`, `unban`, `lock /b/`), a newline, and the reason. A row in
  `action` beside it holds the account, the role, and what was acted
  on; the page shows the role (`system` for ike), never the account.
  The `>>N` gives the target a backlink until it is purged.
- **Ban** suspends the local account behind a signed post: its
  sessions go, and login answers "suspended". Unsigned posts cannot
  be traced to an account, so cannot ban one (Q16 still stands).
- **Lock and unlock** are moderator actions now (Q19's answer, as far
  as this goes).
- **Asking for what already is** (hiding a hidden post, locking a locked
  board, banning a banned account) answers 409 and logs nothing; a
  target that is not there answers 404.
- **The hold** between delete and purge is `hold_seconds`, 14 days by
  default; a timer in the writer purges what is due, at most once a
  minute.
- *Simplifications:* the role is not re-read during a session; log
  threads are monthly rather than one ever-growing thread; reasons
  are free text up to 1000 bytes, not categories; ban targets an
  account through a post it signed, or by number from `/mod` to undo.
  Invariant 8's test does not search `backups/` (D7, Q8).

## lux's answers, 2026-11-15

- **Ranked roles (was Q20).** janitor < moderator < admin. Janitors are
  per board, moderators across all of them; what admins do beyond that
  is Q29. As built:
  - A janitor's group is `ike-janitor-` and a board's name; one group
    per board, and a suffix that is no board's name gives nothing.
  - Nobody bans or unbans an account of their own rank or above, their
    own included. The rank is the one the account had at its last login,
    kept on `actor.rank` and rewritten at every login, so a demotion
    lands then.
  - Nobody undoes a higher rank: unhide and restore need at least the
    rank of whoever last hid or deleted the post. A janitor cannot
    unhide a moderator's hide; a moderator can unhide a janitor's.
  - Checked in the writer's transaction; `/mod` offers only the forms
    that would go through.
  - *Simplifications:* the role is stored flat, a role name and a
    janitor's boards in a second column, not as one structured value.
    An account promoted since its last login, or not logged in since
    ranks came, counts as unranked, so it can be banned by anyone with
    a role until it logs in again.
- **The sandbox (was Q24):** a template unit, under ike's name
  (`ike-strip@`). bubblewrap noted as an alternative.
- **Staging early (was Q25):** uploads that are not yet posted, as on
  Danbooru, in M1, so that archiving is worth doing before posting.
  Invariant 10 becomes real with step 6.
- **No Impressum in ike (was Q26).** ike may be hosted outside Germany;
  amartia.online is for internal testing. If one is needed it becomes a
  wiki page beside "about", linked from the front page, as chaos.social
  does. Notice and action stays a question for when ike is hosted for
  real.
- **The media origin:** lux offered `cdn.amartia.online`; it cannot be
  that, since P3 asks for another registered domain (Q28).
- **Audio** with cover art is a later media type to plan for.
- **Tools (was Q23):** libvips, libjpeg-turbo's `jpegtran`, exiftool in
  the tests only, and the PNG/WebP chunk filter written in Zig. Tests
  stay black-box over the tools and the fixtures.
- **Full checks less often.** theorem is slow and lemma0 (a ccx13: two
  cores, no KVM) is no faster for the VM test. The quick loop (erlfmt,
  xref, the suites touched, eqWAlizer) runs before every commit;
  `nix-build -A checks` once a step is finished, not at every commit.
  This relaxes phi.md's "before committing", on lux's word.
- **I4 (was Q27).** An upload belongs to whoever uploaded it, as on
  Danbooru: an account, or the anonymous actor. Uploading without an
  account is a switch an admin turns on after deploying, off by default
  (A1). A public launch needs uploads that are properly anonymous, so
  the switch has to work before then. The link is plaintext on the
  upload's row; posts show nobody either way.
- **The media host (was Q28):** `cdn.amartia.online` for now, risk
  accepted while ike is not public: same-site with ike and Authelia, and
  sharing `amartia.online`'s reputation. It is one configuration value
  and one module option, so moving to a domain of its own is a
  redeploy.
- **Re-encoding,** for media that will not play as uploaded, needs more
  machine than lemma0: a dedicated transcoding server or rented
  compute. A note for the public launch; M1 strips and never re-encodes.

## The stripper (M1, step 6)

- **`ike-strip`,** a bash driver in `strip/`, built by `nix/strip.nix`
  with a PATH of its own tools only: upload on stdin, `ok TYPE W H
  STORED THUMB` and the bytes, or `no REASON`, on stdout. Caps (bytes,
  side, pixels) and the thumbnail size are its arguments. libvips reads
  the header first (P2) and runs with `VIPS_BLOCK_UNTRUSTED`.
- **lux, 2026-11-16: an archive keeps assets whole.** No colour shift,
  no lost frames, no turned pixels. This overrides P7's "keep a profile
  only if it matches a known standard one, otherwise drop it" and its
  "apply the orientation first": a wording for lux's documents.
- **JPEG** through `jpegtran -copy icc`: the scan and the colour profile
  byte for byte, every other marker gone, the orientation tag with them
  and the pixels not turned (Q32).
- **PNG and WebP** through `ike-chunks`, in Zig: PNG keeps `IHDR PLTE
  IDAT IEND tRNS gAMA cHRM sRGB iCCP sBIT cICP mDCv cLLI` and an
  animated PNG's `acTL fcTL fdAT`, in order, and stops at `IEND`; an
  `iCCP` keeps its profile's bytes and only its free-text name becomes
  "ICC profile". WebP keeps the bitstream, `ALPH` and `ICCP` under an
  extended header saying only "alpha" and "profile", ends at the RIFF
  length, and still refuses animation (M2, unless lux says otherwise).
- **What is stored is decoded whole once,** to make the thumbnail
  (WebP, 256 pixels, `strip`); a file that does not make one is refused.
- **M1 takes JPEG, PNG and still WebP.** GIF and animation are M2, as
  planning's table has them.
- *Simplifications:* chunk CRCs are copied, not checked. A profile's own
  text tags (its description, which can name a device) stay inside it
  (Q32).
- **Invariant 11's test** is black-box over the built tool: four base
  images in the test data, copies loaded by exiftool with EXIF, GPS,
  XMP, IPTC, an ICC profile, comments and trailing bytes; every copy
  strips to its base's bytes, exiftool finds only a bare image's tags,
  and each base's stored hash is written in the test (a tool bump that
  changes it is a migration, P7).

## Uploads and staging (M1, step 6)

- **ike speaks to the stripper over a unix socket,** never through a
  port: `ike_strip` sends the upload, half-closes, and reads the answer.
  In production a socket-activated template unit runs `ike-strip` once
  per connection; in the suites a listener of the test's own does. P1
  says "through an Erlang port"; a socket keeps every process launch
  out of ike's VM, and invariant 3's "nothing leaves the VM" as it was.
- **What the stripper says is checked:** the type from a closed set,
  sizes within the caps ike was given, lengths that add up. The stored
  hash is computed by the writer.
- **`upload`** holds the asset, the sha-256 of the bytes as they came
  (`original`, for matching and bans, not a reference), the actor, the
  time, and `posted`, null while staged. A staged upload keeps its asset
  in the reachability view.
- **Files** live in `assets/` under the state directory, which the web
  server cannot read: `<hash>` and `<hash>.thumb`. The writer writes
  them under a temporary name and renames them before the commit; at
  start it unlinks any with no asset row.
- **Staged uploads are served by ike on the media host only,** through
  links signed with a key held in memory (lost at restart) and good for
  `staged_seconds` (600). The router gives the media host its own
  routes, so the main origin has no such path.
- **The form** is multipart and the only one: the token must be the
  first part, and no file is read before it matches. Up to `files`
  files at once. A refusal says the stripper's reason, the same words
  whatever the file (P6).
- **Images on pages** come from the media origin alone: the main CSP
  gains `img-src` for it, and invariant 2 now allows `<img>` only with
  a `src` there.
- *Simplifications:* staged uploads do not expire yet, and their files
  stay until the sweeper (M2); anonymous uploads (I4's switch) are not
  built; a signed link is a bearer credential for its lifetime, as G7
  accepts.

## Posting images (M1, step 6)

- **A post takes one staged upload of its account's,** picked on the post
  form by radio button; posting marks it posted and sets the post's
  asset, in the same transaction. Someone else's upload, or one already
  posted, is refused and nothing is written. A post with an image may
  have no text.
- **The media origin's files are the assets of shown posts and no
  others:** `<hash>.<ext>` and `<hash>.thumb.webp`, copied from the
  assets by the writer after a commit that may change what is shown
  (a post, or any rung of the ladder), removed when nothing shown uses
  them, and made again whole at start. Derived like the pages, so they
  live in the cache directory, where Caddy reads them for the media
  host; without Caddy, ike serves them there.
- **Pages show the thumbnail** linking to the whole file, both on the
  media origin, with the type and size as the image's text.
- *Simplifications:* one image per post; the board index shows no
  thumbnails; the anonymous post form offers no uploads (I4's switch).

## Blocking and purging images (M1, step 6)

- **Three rungs for a post's image,** on its moderation page: `block`
  puts the stored hash and every hash it came as on the blocklist,
  `unblock` takes them off (by no lower rank than blocked), and
  `purge_image` (admins) blocks for good and destroys it wherever it is:
  every post that showed it keeps its text and says `image` in the words
  of every other gone thing (G5), every upload of it goes, staged or
  not, the asset row goes, and its files under assets and media are
  unlinked after the commit, which folds back the write-ahead log.
- **An upload whose stored or original hash is blocked is refused**
  before any file is written, and every refusal now reads "not taken",
  whatever the reason, so that a refused hash reads like a file that is
  no image (P6).
- **The log says "purge the image of >>N"** and no hash (Q22 still open);
  the `action` row names the post.
- *Simplifications:* a block is reached through a post that shows the
  image; a hash from elsewhere cannot be blocked yet. Unblocking weighs
  the rank of whoever blocked through that same post only. The
  moderator's page says a post has an image but does not show it.
- **Invariant 8** purges an image too: its bytes are in no file outside
  the snapshots, its files are gone by name, no asset, upload or post
  row has its hash, and the blocklist does, which lux kept on purpose
  (C3). Its thumbnail's bytes are not searched for, since another image
  of the same pixels has the same thumbnail.
- **An upload records the post it went into** (`upload.post`, a number).
  Through it `ban` on an unsigned post with an image reaches the account
  behind the image, rank-checked like any ban; the moderator is not
  shown whose it is. A post signed by an account still bans that one.
- **Purging a post takes its image with it** when nothing else uses the
  image any more (no other post, no staged upload): the uploads that
  went into the purged posts go, the asset and its files go, and its
  hashes go onto the blocklist, as planning's Purge row says. That
  includes a hold that ends (Q30). An image another post shows stays.
- **The media directory is made at start,** not only on the first image.

## Several images to a post (lux, 2026-11-16)

- **`post_image`** holds a post's images in order (`post`, `position`,
  `asset`, `gone`), and is in the reachability view. The old
  `post.asset` and `post.asset_gone` are emptied and no longer written;
  SQLite drops no column that is a foreign key, so they stay.
- **The post form offers every waiting upload as a checkbox,** in the
  order shown; the post takes them all or none, up to `images` (8, a
  stub). The post form is now read field by field, so the repeated
  `upload` survives.
- **Each image has its own rungs** on the moderator's page: `block`,
  `unblock` and `purge_image` name the image's place, and the log says
  "purge image 2 of >>N". Purging one leaves the others; purging the
  post takes them all with it, as before.
- **A ban through an unsigned post reaches the account behind its
  images,** which is one account: whoever attached them.

## After the first deploy (2026-11-16)

- **`/account`,** made per request and linked from every page: the name,
  the role (or "no role", which is why `/mod` is a 404), links to
  uploads and moderation, and a log-out form.
- **`/upload` lists posted uploads too,** each with the post it went into.
- **Caddy's unit names the `ike` group** (`SupplementaryGroups`), so
  the switch that adds it restarts Caddy; a reload had kept the old
  groups, and media answered 403 while pages fell through to ike.

## Words for taking things down (lux, 2026-11-16)

- **erasure:** the data is made unreadable on the server, shredded.
  Only a purge erases.
- **hide:** out of every view but moderators' (janitors and up).
- **trash** (was "delete"): hidden, and marked as trash. Kept with no
  end; restore puts it back; `/mod` lists what is hidden or trashed.
  No hold, nothing after it. `post.purge_at` keeps its name, since
  SQLite alters no check, and now says when a post was trashed.
- **deletion:** what a reader sees of a trashed post: gone. On the
  server it is trash.
- **retraction:** a poster trashes their own post; not a moderation,
  not in the public log (next slice).
- **purge:** the data is illegal or malware, and is erased. A purged
  post's text is erased; its images are not its content and stay, kept
  and out of sight unless another post shows them. `purge_image` erases
  an image and blocks its hashes. This takes back what 36626e0 did, and
  what a hold's end did, by lux's word; invariant 8's "content" is now
  read as the post, and an image only when it is purged itself.
- **Nothing expires.** No hold, no sweeper, no staged uploads collected.
  Planning's Delete row ("then purged"), its retention table and the GC
  sweep (lines 167, 183–205, 200) and the Upload row's "collected after
  a time limit" are wording for lux's documents.
- **Also lux's word:** SVG beside SWF, in the same milestone, against
  P5's "never"; meshes, Live2D and MMD as downloads only, for now; the
  wiki before the public launch, which lifts S2 for M3.

## Retraction (lux, 2026-11-16)

- **A post may carry a password,** given on either post form, as vichan
  has it. Kept is a 16-byte salt and PBKDF2-SHA256 (100000 rounds) of
  it, per post, worked out in the request's process, never the password;
  one password on two posts leaves nothing in common. Planning line 11's
  "nothing kept but the text" now has this exception: wording for lux's
  documents.
- **`/p/N/retract`** trashes the post (`retracted = 1`), with its
  password, or for a post an account signed, by being that account; an
  unsigned post is nobody's, so only its password retracts it. Not in
  the log; the moderator's page says "retracted by its poster", and
  restore (moderators and up, as for any trash) puts it back.
- **The form is folded under every post,** in a `<details>`, on the
  static pages, with a link to the post's moderation page beside it. A
  page that is the same for everyone carries no session token, so the
  handler takes the browser's `Origin` instead (it must be this site's
  host; missing or `null` is refused) and the limiter allows ten tries
  at one post's password an hour. Retracting a thread's first post
  takes the thread out of view, as trashing it would.
- *Not possible on static pages:* a post hidden from all but its own
  poster. The moderation forms stay on `/mod/post/N`, behind their
  tokens, until lux says whether tokenless forms guarded by `Origin`
  are acceptable (Q33).
- *Fixed on the way:* the restore rank check still looked for the
  old kind name `delete`; it reads `trash` now.

## The thread form (lux, 2026-11-16, after vichan and tinyboard)

- **One form per thread page:** a checkbox in every post's header, and at
  the foot a password with "retract", a reason with "report", and,
  folded in a `<details>`, the moderators' hide, trash, purge and ban.
  The page is the same for everyone; to anyone without a role those
  buttons answer 403 and change nothing. The forms folded under each
  post (retraction's first form) are gone, and so is `/p/N/retract`.
- **`/act`** takes the ticked posts (at most 50) and one kind.
  `guard/1` stands in for a session token, which a static page cannot
  carry: the browser's `Origin` must be this site. It is the one place
  to change if the form should carry a token later (lux: "implement
  either and allow for future changes"; 4chan's way, as lux recalls).
  Hazard I2's token rule has this exception.
- **The browser keeps its password,** as vichan does: the post form
  fills in one made up once and kept in a `__Host-` cookie (a year,
  HttpOnly, SameSite=Strict), and `/act` uses it when none is typed.
  Retractions are trash: out of view, seen by moderators and up.
- **Reports** keep the post's number, the reason and the time, nothing of
  who sent them; `/mod` lists the open ones (a janitor's for its boards)
  with a dismiss form. A purge takes a post's reports with it, since a
  reason may quote what it reports.
- *Not built:* vichan's "file" box, retracting only a post's images.
