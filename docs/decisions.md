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
- **The hold** between delete and purge is `hold_seconds`, 14 days by
  default; a timer in the writer purges what is due, at most once a
  minute.
- *Simplifications:* the role is not re-read during a session; log
  threads are monthly rather than one ever-growing thread; reasons
  are free text up to 1000 bytes, not categories; ban targets an
  account through a post it signed, or by number from `/mod` to undo.
  Invariant 8's test does not search `backups/` (D7, Q8).
