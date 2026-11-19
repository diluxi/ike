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

## M2: the booru, first slice (2026-11-16)

- **lux, on meshes:** accounts may upload any mesh, MMD and Live2D zips
  included, without zip checks, since accounts are trusted; uploads
  without an account (when that switch is on) take only static formats,
  points and textures (`.glb`, `.stl`, `.ply`, `.obj`). Not built yet.
- **M2 begun on lux's word,** with M1 still owing files on the post form,
  the anonymous switch and vichan's "file" box.
- **An entry, `##N`,** is `booru` (its own number, its time, a state as a
  post's) over `booru_version` (append-only, position from 0, asset or
  a gap). One entry per asset, by a unique index. Every posted image
  gets one at once (`booru_at_once`, true: planning line 243 is open);
  the entry names no one. Images posted before the booru get entries at
  start, numbered in the order they were first posted.
- **`shown_entry`** is an entry as pages show it: shown, with its newest
  version. Media now follows shown posts *or* shown entries: hiding or
  purging a post leaves its image public on its entry until the entry
  is taken down too (lux: the image is the archive's). That flips what
  the asset suite and invariant 8 asserted before.
- **Pages:** `/booru` (the newest 100, thumbnails) and `/booru/N` (the
  newest version, every version, the posts that show it, the posts
  that point at it), static like threads; the writer unlinks the page
  of an entry taken down, after the renderer settles it.
- **`##N`** in post text links to `/booru/N`, kept in `link.booru`;
  to nothing it reads as every other link to nothing.
- **Entries are moderated as posts are** (hide, unhide, trash, restore
  at `/mod/booru/N`, logged as "hide ##N" with `action.booru`), on a
  board called `booru`: a janitor of `/booru/` keeps them.
- **`purge_image`** leaves the entry's version empty, a gap.
- *Not yet:* tags, search, entries from `/upload`, versions and
  upgrades, video (ffmpeg, a dependency to ask for), hover cards (they
  need a script).

## M2: tags and search (2026-11-16)

- **A tag name** is 1 to 64 of `a-z 0-9 _ ( ) ! ? : . ' -`, not starting
  with `-`, `~` or `*`, lowercased as typed; the schema checks the same.
  What is not a name is dropped. So a name sits in a link or a search
  with nothing to escape there.
- **`tag`, `booru_tag`, `tag_change`:** a name once, an entry's tags, and
  a history (entry, account, time, added, removed). Entry pages show
  what changed and when, not who; the history keeps who (Q34).
- **Accounts tag directly** (until proposals, M4; Q34): `-name` takes
  one off, on a form on the entry's page, guarded as the thread form is
  (`ike_http:guarded/1`, now shared by both). An entry out of sight is
  not tagged.
- **Search,** `/booru/search?tags=a b -c d*`, made per request: every
  name, none of the minus ones, and for each `d*` a name that starts
  with it, through an FTS5 index of tag names (prefixes of 2 to 4 are
  indexed). The newest hundred; no paging yet.
- *Not yet:* tag categories, counts, aliases and implications (BURs are
  M4), paging.

## Video (M2, lux 2026-11-16: "add ffmpeg")

- **ffmpeg-headless** from the pinned nixpkgs (9.0.2), in `ike-strip`'s
  PATH and the sandboxed unit, and in the tests and shell for the
  corpus.
- **WebM** (VP8, VP9, AV1; Opus, Vorbis) and **MP4** (H.264, HEVC, AV1;
  AAC, MP3, Opus), by magic and then by what ffprobe reads. Anything else
  is refused ("unplayable"): re-encoding is for other hardware, later.
- **Remuxed, never re-encoded:** the first video stream and the first
  audio stream if there is one (`-map 0:v:0 -map 0:a:0?`), so data
  tracks such as GPMF go; `-map_metadata -1 -map_chapters -1`;
  `+bitexact` so the muxer writes no version; for H.264 and HEVC the SEI
  units, where an encoder writes about itself (x264's settings, a
  camera's), are filtered out. The same video with other metadata comes
  out as the same bytes (golden hashes in invariant 11).
- **Caps:** side and pixels as images, and `maxSeconds` (600, a stub),
  ike-strip's fifth argument. The thumbnail is the first frame.
- **`asset.format`** holds the type now, since `asset.type`'s check names
  images only and SQLite alters no check; `type` is kept for images and
  no longer read.
- **Shown as `<video src poster preload="none" controls>`,** which plays
  without a script; the CSP gains `media-src` for the media origin, and
  Caddy serves `.webm` and `.mp4` from it.
- *Not yet:* GIF (planning lists it with video), duration on the page,
  the moderator's page showing the video.

## M3: the wiki, first slice (2026-11-16, before launch on lux's word)

- **A page is a thread on the board `wiki`,** its first post the first
  revision (planning, Model). An edit is a reply holding the page's
  whole new text, marked `revision`, with the revision it was made on in
  `base`; other replies are the discussion, at `/board/wiki/N`. `page`
  maps a name to its thread. A page reads as its newest shown revision,
  so hiding a revision steps the page back.
- **Names** are tag names (spaces become `_`) that do not start with a
  dot, since a name may become a file's.
- **Accounts write** (anonymous edits are proposals, M4), unsigned unless
  "sign" is ticked, as posts. An edit on a revision that is no longer the
  newest was refused at first; edits now stack (below, "Edits stack").
- **`[[name]]`** links to the page; with no page but a tag by that name,
  to the tag's search; else it reads as every other link to nothing.
  Kept in `link.name`; starting a page re-renders the threads that
  pointed at its name.
- **History** shows each revision against the one before, newest first,
  by lines (`ins`, `del`), from a longest-common-subsequence diff made
  when the page is shown, as planning has it.
- *Simplification:* pages, history and the index are made per request,
  not written as files as planning has current pages; reverse links of a
  page (what points at it) are not shown yet.
- *Not yet:* renames and redirects, tag pages, the threaded view,
  promoting a reply to a thread or a page.

## The look of things (lux, 2026-11-16)

- **A stylesheet,** `/style.css`, plain: what a revision adds green, what
  it takes red, a revision's count beside its header until opened, the
  gone grey, titles bold. Written by the renderer, served by ike, and
  allowed by `style-src 'self'`. Nothing depends on it. Invariant 2 now
  allows exactly that one `<link>`.
- **A wiki page's thread is its history and its talk,** newest first
  (`<ol reversed>`): each revision shows what it changed of the one
  before, folded in a `<details>` beside its header (`+2 -1`), the
  newest open; replies that are not revisions read as posts.
  `/wiki/NAME/history` leads to the thread; `wiki_history = separate`
  brings the separate page back, should that be wanted.
- **Posts may have a title,** one line of at most 100 characters, on
  both post forms. A titled thread is headed and listed by its title; a
  wiki page's thread is titled with its name.
- **A signed name links to `/user/NAME`,** the account's page: what it
  signed, newest first, made per request. Lux's user boards grow from
  here (Q10, Q14).

## Files on the post form (lux, 2026-11-16)

- **Both post forms are multipart** and take files beside the text and
  any ticked uploads; each file is stripped and kept as an upload, then
  posted with the text, all or none. `/upload` stays for batches.
- **The token comes first:** `ike_http:submitted/2` reads fields in
  order and reads no file before the form's token has matched (the
  session's, or for nobody the form cookie's). Invariant 5 now posts a
  file that is no image to the post form: refused, nothing kept.
- **Nobody posts files only when `anonymousUploads` is on** (off by
  default; lux, against A1 as written): still images only, an animated
  PNG refused, posted at once as uploads of the anonymous actor, never
  staged (invariant 10 has nothing of nobody's to guard).

## Tags by what an entry is (lux, 2026-11-16)

- **Inherent tags:** an entry is tagged `image` and `raster` for a still
  or animated image, `animation` for an animated PNG, `video` for WebM
  and MP4, `audio` for a video with sound; never a tag for an absence
  (lux, on Danbooru's `original`), so `video -audio` finds the silent
  ones. ike puts them on when an entry is made, and on every entry at
  start; no history line names anyone for them.
- **`asset.traits`** keeps what the stripper found beyond the format
  (`audio`, `animated`); ike-strip's answer has a seventh field for it,
  and an animated PNG is told by its `acTL` chunk.
- *Not yet:* `vector` and `mesh`, with SVG and meshes (M6 and later).

## Markup (lux, 2026-11-16: "a danbooru-like wiki text")

- **A subset of DText** (Danbooru), parsed by `ike_markup` into a tree
  whose leaves are text: `h1.` to `h6.` (shown one level down, under the
  page's own title), `* ` lists, `[quote]` and `[code]` on lines of their
  own, paragraphs between empty lines; inline `[b] [i] [s] [u]
  [spoiler] [code]`, `"label":[https://url]`, bare http(s) urls,
  `{{tags}}` as a booru search, `[[name|label]]`. A tag left open, or a
  close with nothing open, is text as typed. `>>N`, `##N` and `[[name]]`
  are still ike_text's to find, inside the markup, so the writer and the
  pages read links alike (D1).
- **Addresses** are http or https, printable, without quotes, angle
  brackets, backslashes or backticks, shown with `rel="nofollow
  noreferrer"`. Invariant 4 now allows such hrefs, checks no tag holds a
  `javascript:`, and posts markup made to break out.
- **Keys:** `/ike.js`, ike's own and no library, for whoever runs
  scripts: Ctrl+Enter sends the form, Ctrl+B and Ctrl+I put `[b]` and
  `[i]` around the selection. Every page works without it; invariant 2
  allows exactly that one deferred script from this origin, and the CSP
  gains `script-src 'self'`.
- *Not yet:* nested lists, tables, `[tn]`, `[expand]`, DText's other
  link forms; markup in titles and on the moderator's page (plain text
  there).

## Red links

lux, 2026-11-16: `[[doesn't_yet_exist]]` links to the page asking for
it to be started. A name with neither a page nor a tag is now an anchor
of class `missing` (red) to where its page would be, and not grey text.
Every wiki href and Location is made by `ike_wiki:path/1`, which writes a
name's `?` as `%3F` (it would start a query) and its `'` as `%27`; the
router reads both back. The invariant suite's href check admits exactly
`/wiki/` and a name's characters so written.

## Edits stack, and amend (lux, 2026-11-16)

- **No merge, no refusal** (Q35, planning line 253): "whomever posts
  first causes the edit first, all other edits are stacked on top, and
  users may retract them if that caused inconsistencies." An edit is the
  next revision over the newest, whatever it was opened on, and `base`
  says which revision it went over. The form no longer carries one.
- **Retraction undoes a revision,** as any post: a signed one by its
  account, an unsigned one by its password, which the wiki form now
  takes (filled in from this browser's, as the post forms). A page reads
  as its newest shown revision, so retracting the newest steps it back.
- **Batching is amend:** an edit right after its own author's revision,
  with nothing shown posted between, replaces that revision's text and
  time instead of adding one, so its diff is everything both edits did
  (git's `commit --amend` replaces the newest commit the same way). The
  revision's links are read again from the new text, and every page
  either text pointed at is made again.
- *Simplification:* "the same author" is a signed account only. An
  unsigned edit is the anonymous actor's, which is everyone's, so the
  actor alone would fold strangers' edits together. lux wrote
  "user/anon": the one thing that could tell two unsigned edits apart is
  the password, a new edit's opening the seal of the one before (never an
  address, by rule). Not built unasked (Q36).
- **What a fold replaces is discarded** (lux, Q36): nothing keeps an
  intermediate edit. Squashing may later become a switch (and
  unsquashing with it); turning it on or off then will not touch edits
  made before.
- *Not yet:* amend for tags (Q37), which needs the curation's thread
  first.

## Asset, meta, tack, curation (lux, 2026-11-16; recorded, not built)

lux's model, in lux's words where they are given:

1. **An asset** is the bytes, at `cdn.amartia.online`.
2. **A meta** is what is known of an asset: its owner (or the anonymous
   actor), the EXIF that stripping spares, attribution where there is
   one (later read by ike itself when it archives others' posts),
   similarity hashes later, its size. Metas live at `/trunk`. lux on
   Danbooru's media asset page, the full EXIF dump: hard to justify. The
   meta shows only what stripping kept (invariant 11), and whether a
   meta has a page of its own or `/trunk` is only a list is open (Q38).
3. **A tack:** an asset shown in a board post, tacked to the board. Not
   a pinned post, which is held at the top of a board.
4. **A curation:** an asset tagged, perhaps translated, with its
   artist's commentary, and posted to the booru; what Danbooru calls a
   post and ike has called an entry. It is missing its comment section:
   a reverse board, as a wiki page's thread, with changes to its tags,
   attribution and commentary (later translation notes) shown as diffs
   between the comments.

- **Uploads are public by default** (Q31): a staged asset is listed in
  `/trunk`. An account may mark one private: still in the trunk, seen
  only by its owner and moderators and up. A private asset may be
  curated privately, as a comic tagged in full before it is released,
  and a curation may later be embedded in a followers-only post
  (ActivityPub).
- **Moderators and up see every asset:** to them `/trunk` lists the
  private metas as well.
- Invariant 10 now reads (lux, 2026-11-17): "A private meta is served
  only to its owner and moderators. Moderators see all metas in the
  trunk. Users see only public and their own metas." Built: "The trunk,
  first slice", below.

## A page outlives its first revision (lux, 2026-11-17; Q39)

- **On the wiki board, a thread stands while any post of it is in
  view** (migration 0020 widens `shown`; elsewhere a thread still goes
  with its first post). A first revision retracted, hidden or trashed
  leaves a tombstone: the page's name as title, "taken down", nothing
  of its text. With nothing else in view the thread is gone, as before,
  and the next edit starts the page again in the same thread, under the
  tombstone.
- **The next revision in view takes over** what one out of view did: it
  is shown as its change from the revision in view before it, and the
  first in view reads as the page's start. This holds past the first
  revision too. A talk post between the tombstone and the next revision
  reads as if it came first; lux: that is fine.
- **Revisions are named `<page> <n>`,** n counted over the revisions in
  view, so a revision's number moves when one before it is taken down.
  *Simplification:* the count is made when the page is rendered and
  kept nowhere. The thread is headed by the page's name.
- **A revision's count is coloured:** `+n` green, `-n` red.
- *Unchanged:* purging a page's first post purges its whole thread, as
  on every board.

## The trunk, first slice (lux, 2026-11-17)

- **A meta per asset,** made when the asset is first uploaded, by
  whichever form: `meta` (migration 0021) holds its owner (that upload's
  actor; the anonymous actor for nobody's), when, and whether it is
  private. Metas are part of the reachability view, and purge_image
  takes the meta with the asset (invariants 8 and 9, their tests
  extended).
- **Public unless ticked private** on `/upload`; only an account's
  upload can be private. The owner switches it either way on the meta's
  page. A public meta's files are on the media origin as a shown post's
  are; a private one's are reached only through the short-lived signed
  links (G7's mechanism, kept), which only pages asked for by the owner
  or a moderator carry. A signed link now works for any upload, not only
  a staged one: only pages that may show the file make one.
- **`/trunk`** lists the newest 200 metas the asker may see: public ones,
  their own, and to moderators and admins all (janitors are not
  moderators here). **`/trunk/HEX`** is a meta's page: the asset, its
  type, size, upload time, who sees it, what it is (traits), the shown
  posts that tack it, and to its owner "owner: you" and the switch. A
  meta the asker may not see is the same 404 as one that is not there.
- **Nobody was told whose a meta is** in this first slice; lux has since
  decided otherwise (below, "Metas: names, moderation, known bytes").
- **Migration:** existing assets get a meta owned by their first
  upload's actor, private if never posted (they were staged under the
  old invariant 10, so seen by their uploader alone), else public.
- *Simplification:* one meta per asset, its first uploader's. A second
  account uploading the same bytes owns nothing of it (Q41: it is sent
  to the meta instead).
- The asset suite's "media follow what is shown" case uploads
  privately, since a public meta keeps its files public whatever is done
  to the posts and entries showing them.
- *Not yet:* paging, curations in the list (marked), comments on a meta.

## Curation (lux, 2026-11-17; built: see "Curation, first slice")

- **Every asset goes the same way:** uploaded (by a tack, by a user
  bringing their own work, later by archiving another site's post), it
  gets a meta. Tacks make metas, never curations (`booru_at_once` is to
  go).
- **A meta's page has a comment thread** below it, and a field for tags,
  space-separated for now, with a button that curates it: posts it to
  the booru. Its comments then move to the curation's page, and the
  meta's link leads there.
- **The curation page stays a Danbooru-style page,** as entries are
  now. Its comment section holds, between the comments, revision posts
  as the wiki's: a `<details>` whose summary counts the tags added and
  taken and summarises the commentary's diff. Not reversed, unlike the
  wiki. No separate `/booru/` board: the thread lives under the entry.
- **`/trunk`** lists metas and curations both, curations marked.
- A private meta can be curated privately (a comic tagged in full before
  release).

## Metas: names, moderation, known bytes (lux, 2026-11-17)

- **A meta bears its owner's name, or reads as anonymous** (Q42),
  linked to `/user/NAME`. Whether it is named is the upload's own
  choice, as a post's is: `/upload` has a "sign as NAME" box, and a file
  sent with a post is signed when the post is. The owner stays the
  account either way (the private switch and moderation need one); only
  the name shown follows the box. Existing metas were never signed.
  Its owner is also told "(you)".
- **Moderators hide and trash metas** (Q40), at `/mod/meta/HEX`, linked
  from the meta's page for them: the same rungs, roles and log as a
  booru entry's, on the trunk as a board. A meta not shown is gone from
  `/trunk` and its page for everyone but moderators (its owner too, as
  with posts), and its files leave the media origin unless a post or an
  entry shows them. The public log names a public meta by its first 12
  hex digits, and a private one only as "a private meta" (now by
  number for both, below). `action.meta`
  keeps the hash for moderators, and purge_image clears it (invariant 8,
  test extended).
- **Known bytes lead to what is known of them** (Q41, refined below in
  "Metas are their owners'"): one file uploaded
  at `/upload` whose meta the uploader may already see sends them there,
  to its booru entry if it has a shown one, else to its meta. Bytes
  under someone else's private meta go to `/upload` as any upload does,
  so that nothing says they exist. *Simplification:* with several files
  at once, nobody is sent anywhere; nor from the post form, where the
  post is what was asked for.
- *Owed with curation:* curations bear their owner or anon, and tag and
  commentary revisions are signed or not as wiki revisions are.

## Quotes, nested lists, and the wiki page's look (lux, 2026-11-17)

- **`> ` before a line quotes it,** and a quote holds blocks, so lists
  and quotes nest in it (`> > `). `>` with no space after stays text, as
  imageboard greentext; `>>N` is still a link. `[quote]` still works.
- **Stars give a list item its depth:** `* `, `** `, `*** `. An item
  deeper than the one before hangs under an item with no text.
- *Simplification:* quotes and lists go eight deep; past that, quote
  lines are text and items stay at the eighth level. Nothing else
  limits them but a post's length.
- **A wiki page's title has its edit link beside it** (`a.edit`, a word
  until there is a pen), and `e` follows it where scripts run, unless a
  text box or a modifier key has the keypress. The history and
  discussion links are gone: the "as of >>N" note leads to the page's
  thread, which is both.

## Metas are their owners' (lux, 2026-11-17)

- **A meta is an owner's, not an asset's** (Q41; migration 0023). Bytes
  under someone else's private meta, uploaded again, get a meta of the
  uploader's own, and nothing tells either that the other exists; the
  asset is still one, by its hash. An asset has at most one public
  meta, and each owner at most one meta of it. Uploading bytes that have
  a public meta, or one of your own, makes none and leads to it.
- **Publishing is making a meta public** (lux's correction: not
  curating). The first owner to do it holds the asset's public meta;
  another owner making theirs public is sent to that one, and theirs
  stays private, with whatever it has (its comment thread, once there
  are threads). When the public meta is curated, its thread moves to the
  curation; private ones never merge into it, since that would show them
  without their owners' say.
- **Metas are numbered:** `/trunk/N`, `/mod/meta/N`, "meta #N" in the
  log, for private ones too (a number says nothing of the bytes).
- **Owner text** (Q42): to its owner, "(you)", a link to their user
  page; to others the owner's nick as a link, or "anonymous". The owner
  of an unsigned meta can sign it later ("sign as NAME"), which is how
  they take it as theirs in public; signing is not undone.
- **A trashed meta stays visible to its owner** (Q40), marked trashed,
  its files kept and shown to them by signed links, until a moderator
  restores it or an admin purges the asset. *Interpretation:* lux wrote
  "trashed posts"; built for metas only. A hidden meta stays out of its
  owner's sight, and board posts are unchanged: their pages are the same
  for everyone, and an unsigned post has no owner to show it to (Q43).

## Fonts (lux, 2026-11-17)

- **TTF, OTF, WOFF and WOFF2, uploaded by accounts only** (fonts carry an
  RCE risk): from `/upload` and the post form. Nobody's files are still
  images, so nobody posts a font. Font collections (TTC) are refused.
- **New dependencies, approved by lux:** OpenType Sanitizer (OTS 9.2,
  Google's; what Chrome and Firefox run every web font through) and
  fontTools (Python, with brotli for WOFF2). Both run in ike-strip,
  outside the BEAM (invariant 6), and neither renders a glyph.
- **The stripper's way:** OTS sanitises the upload; ike-font cuts its
  name table to the names that say which font it is (IDs 1, 2, 4, 6, 16,
  17, 25) and those its own tables point at (256 and up: axis and
  instance names), blanks the OS/2 vendor id, drops DSIG and meta, and
  saves it in the format it came in with no timestamp touched; OTS
  checks the result. *As uploaded, as near as can be:* OTS rewrites
  every font it passes (tables it does not know go), so the stored bytes
  are never the upload's; the format is kept, and WOFF and WOFF2 are
  compressed again by fontTools. Converting to one format (WOFF2) and a
  download in any format are left for the transcoding VM (lux).
- **Credits are commentary, not the file** (lux): every other name
  record (copyright, designer, manufacturer, URLs, license, version,
  description...), the vendor id and a WOFF's metadata block are kept
  with the upload (`upload.commentary`), and the meta shows its owner's
  upload's as "commentary", as Danbooru shows an artist's. So the same
  font credited to someone else is the same asset, and Q41's rules lead
  the second uploader to the meta there is; their own commentary is kept
  with their upload all the same. *Not kept:* a WOFF's private data
  block, which is no text.
- **Thumbnail:** a black F drawn by libvips' text in the font, on a
  transparent background (lux), with a fontconfig that knows no font but
  this one, so nothing falls back unseen. Drawn in the stripper, which
  is to move to its own VM with transcoding (lux).
- **Trying a font out,** on its meta's page and its entry's: the
  thumbnail, a line of text to type, and sliders for size, weight (the
  font's own `wght` axis if it has one, else 100 to 900 for the browser
  to make) and every other axis. ike.js loads the font from the media
  origin with `FontFace` and moves the sample with the sliders.
  *Simplification:* without scripts the sample stands in the page's own
  font; the thumbnail still shows the font.
- **Serving:** `font-src` the media origin in the CSP; the media origin
  sends font/* types and `Access-Control-Allow-Origin: *` for fonts,
  which load with CORS. *Any* origin, since ike has no configured origin
  of its own to name, and a font's bytes are public or behind a link
  that is its own credential; it lets other sites load public fonts too.
- **Tags:** a font is tagged `font`. *Not added:* a tag for variable
  fonts (the trait is kept as `variable` on the asset).
- **Schema** (0024): `asset.filetype` replaces `format` for reading, its
  check only a name's shape, so that the next kinds (SVG, meshes) need
  no migration; `asset.family`, `asset.axes`; `upload.commentary`. A
  font has no width or height (null, shown as none).
- **Found on the way:** purge_image unlinked only a still image's files,
  never a video's; it now unlinks every kind (invariant 8).

## Curation, first slice (lux, 2026-11-17)

- **A tack makes a meta and no entry:** `booru_at_once` (planning's open
  item, line 243) now defaults to off, on lux's word; it stays a switch,
  and the booru and asset suites test with it on.
- **Curating:** on a public, shown meta's page, any account enters tags
  (space-separated, `-name` takes one off) and posts it to the booru,
  signed or not. That makes a booru entry (the curation) of its asset,
  with the tags given and what the asset is (inherent tags), owned by
  the meta's owner and named as the meta is. The meta's page then leads
  to it, and `/trunk` lists the meta marked "curated as ##N", linking
  there. Bytes already on the booru are not curated again; the form
  leads to their entry.
- **One thread:** a meta's comment thread lives on the board `trunk`,
  attached (`board.attached`): no index, no thread pages
  (`/board/trunk` leads to `/trunk`, a thread's page to its curation or
  meta), no new threads from forms, not in board lists, accounts only
  (locked). Curated, the meta's thread simply becomes the curation's
  (`booru.thread`), so nothing is copied; replies go through the
  thread's own reply form and are read on the curation's page.
- **Revisions between the comments** (lux): the curation and every
  change to its tags or commentary is a post marked `revision` in the
  thread, holding the whole state (tags on the first line, commentary
  after). The page shows each as what it changed of the one before, in
  a `<details>` beside its header: "tags +2 -1, commentary +1",
  coloured, with the tags put on and taken off and the commentary's
  lines; titled `##N n`. Not reversed, unlike the wiki. Signed as the
  account asks (a "sign" box), else anonymous; an account's change right
  after its own signed revision is folded into it, as the wiki's amend
  (Q37). The tag history (`tag_change`) still keeps the account.
- **The curation page** keeps its Danbooru-like shape: the asset (a
  font tried out), its owner, tags, commentary, one form for tags and
  commentary, versions, where it is shown, then the comments. An entry
  with no thread (made at once, before curation) shows the old tag
  history list instead.
- **Privacy:** the `shown` view (migration 0025) shows an attached
  thread only as its curation or its public, shown meta is shown. So a
  private meta's comments are in no page made for everyone, on no user
  page, in no reply list, and not found by `/p/N` (a permalink finds only
  what everyone is shown, so not even their owner gets one). They are
  read on the meta's own page, by whoever may see the meta, and only
  they comment there. Invariant 10's test now covers this.
- *Simplification:* only public metas are curated. Curating a private
  meta privately (lux: a comic tagged before release) needs a curation
  page for its owner and moderators alone, beside the static, public
  one: Q45.
- *Simplification:* the font's own commentary stays on its meta's page.
  (Commentary was plain text at first; it is ikext now, below.)

## ikext: commentary, meta #N, booru #N, preview (lux, 2026-11-18)

- **ikext** is ike's text: the DText subset posts, wiki pages and now a
  curation's commentary are written in (Q45: commentary is markup).
- **A hashtag is text** (lux): a curator who brings commentary from
  twitter makes its hashtags links by hand, `"#tag":[https://...]`;
  ike links nothing of `#word` by itself.
- **`meta #N` links to the meta, `booru #N` to the curation** (the same
  entry as `##N`, written as a curation is called), each a word of its
  own ("submeta #1" is text). A meta is a link only while everyone may
  see it (public and shown), so a private meta's number links nowhere
  and says nothing. *Simplification:* no row keeps `meta #N` the way
  `link` keeps the others, so a page naming a meta is not made again
  when that meta becomes public; the thread's next change shows it.
- **Preview:** every form that takes ikext (the post forms, a wiki edit,
  a comment, a curation's commentary) has a "preview" button that sends
  the form to `/preview` in a tab of its own, urlencoded (`formaction`,
  `formtarget`, `formenctype`), so the form keeps what was typed, no file
  goes with it, and no script is needed. Nothing is written; anyone may
  ask, and the limiter counts it as any POST. Invariant 4's test covers
  it as a per-request page.

## The tag box (lux, 2026-11-18)

- **One box, the whole of an entry's tags:** a monospace, many-lined box
  on the curate form and the curation's form, holding every tag the
  entry has, laid out as its curator likes (one name or several a line).
  What it names is what the entry has; `-name` takes one off, wherever
  it stands. Kept as laid out, tidied: a name twice stays where it was
  first, a name taken off goes from every line, a line left empty goes.
  lux's example comes out as lux wrote it but for one place: the last
  line's new name, feet_out_of_frame, stays on its own line rather than
  joining the line full_body left (ike does not guess where a name was
  meant to go). A revision keeps the box as laid out, so the next one
  opens on it.
- **The first revision counts only the curator's tags** (Q45): what ike
  tagged the asset with by what it is (image, raster, font...) is where
  the count starts.
- **Tag names beyond ascii** (lux's example: copyright:ガールズバンドクライ):
  ascii is the closed set it was; any other character too, but the
  spaces unicode has; 64 characters at most. Migration 0026 makes the
  tag table again for its check (rows and ids kept, booru_tag's keys
  checked at the end). Links percent-encode what is beyond ascii, in
  tag searches and in wiki paths alike (a page's name is a tag's).
- **A font's page** has no thumbnail (lux): in its place, its text, which
  the reader types over, in a many-lined box drawn in the font, with
  the sliders below. A `textarea` and not `contenteditable` (lux asked):
  it is the plain-text, many-lined field a form already has, and
  `contenteditable` takes in pasted styles (`plaintext-only` would not,
  but is newer). The trunk and the booru still show the F.

## The front page (lux, 2026-11-18)

- After rain.meth.cat's front page, in layout only (no styles yet):
  where to go (board, booru, trunk, wiki), the 15 newest curations as
  thumbnails, and the 15 newest board posts, each its board and its
  first words (its title, if it has one) linking to it. Not the log's,
  the wiki's or the trunk's posts, which are read where they belong.
- Made again whenever a board's page or the booru's is, with the list
  of boards.

## Nobody's comments, when an admin lets them (lux, 2026-11-18)

- **The trunk is opened and shut like a board** (its `locked` flag), but
  only by an admin (lux: "enabled by an admin"); a moderator may not,
  and only an admin's moderation page lists it ("comments on metas and
  curations", migration 0027). It begins shut.
- **Open:** nobody comments on a public, shown meta from its page (the
  form sent from this site only, as the thread form is, and at the
  trunk's pace, as a board's), and on a curation through its thread's
  own reply form, with everything nobody's posts have there (the form's
  token, the board's pace, the limiter). A private meta's thread stays
  its owner's and the moderators'.
- *Not here:* nobody's password on a meta's comment (the board forms
  take one); nobody's files on comments, which follow
  `anonymous_uploads` through the thread form only.

## Cards, prefix:what, outlinks, comments' passwords (lux, 2026-11-18)

- **A curation is a card** (lux: a cardboard box). Pages say "card:N"
  (the card's page, revisions "card:N n", the trunk's mark, the front
  page's "recent cards"); the booru, its tables and `/booru/N` keep
  their names. `##N` still links, written as typed.
- **`prefix:what` replaces `meta #N` and `booru #N`:** `meta:N` and
  `card:N` link inside ike; and somewhere else's, at a word's start,
  marked as outlinks:

  | prefix | what | leads to |
  |---|---|---|
  | twitter | a number / a name | x.com/i/status/N / x.com/name |
  | pixiv | a number / users/N | pixiv.net/artworks/N / pixiv.net/users/N |
  | tumblr | blog or blog/N | tumblr.com/blog/N |
  | danbooru | a number | danbooru.donmai.us/posts/N |
  | gelbooru | a number | gelbooru.com/index.php?page=post&s=view&id=N |
  | e621 | a number | e621.net/posts/N |
  | github, codeberg | a path | github.com/path, codeberg.org/path |
  | sourcehut | ~user/project | sr.ht/~user/project |
  | 4chan | board or board/N | boards.4chan.org/board/thread/N |
  | xdnmb, A岛匿名版 | a number | www.nmbxd1.com/t/N |
  | komica, 糟糕岛 | a path | komica1.org/path |

  A path is letters, digits and `_ . ~ / -`, never `..` or `//`; what
  ends a sentence is not part of it. What fits no shape of its site is
  text. *To be checked by lux:* the addresses are ike's reading of each
  site; komica's and xdnmb's especially (both move, and komica's boards
  differ), and whether twitter should be x.com or twitter.com.
- **Every link out of ike** (outlinks, `"label":[url]`, bare urls) has
  `class="out"`, and the stylesheet puts ↗ before it. *Not yet:* lux's
  favicons (Q47).
- **A meta's comment takes a password**, filled in from this browser's
  as on the boards, and the comments on a meta's page and a card's page
  are ticked and retracted (or reported) through `/act` as a board's
  posts are, which leads back to the meta or the card.

## SVG (lux, 2026-11-18)

- **Uploaded by accounts** (nobody's files are still raster images), from
  `/upload` and the post form; tagged `image` and `vector`; served as
  `image/svg+xml` from the media origin under its sandbox CSP.
- **An allowlist, not a filter** (`strip/ike-svg`, Python's own XML
  parser, no new dependency): SVG's drawing elements and the attributes
  that say how; `href` only to `#id`; style only with no address but
  `url(#id)`; text in text elements. Everything else goes: scripts,
  `foreignObject`, event handlers, links out, other namespaces (an
  editor's, with its file names), comments, `metadata`, `title` and
  `desc` (an author's words), embedded images (their own metadata). A
  DOCTYPE or an entity is refused outright (no billion laughs). The same
  input is the same output; invariant 11's test has a drawing laden
  with all of it strip to the same bytes as the drawing alone.
- **Its thumbnail:** libvips' SVG loader is one it does not trust with
  hostile input (librsvg), and ike-strip blocks such loaders. It is let
  for the thumbnail of the allowlisted copy only, which is no longer the
  upload. *A judgment call, lux's to overrule:* the other way is no
  thumbnail for SVG at all, or rasterising in a unit of its own; it
  moves with the stripper to its own VM anyway.
- *Simplification:* an embedded raster image in an SVG is dropped, not
  kept and stripped.

## Where the stripper runs (lux, 2026-11-18)

- **`services.ike.strip.isolation`:** `sandbox` (a unit on ike's host,
  as before), `microvm` (now: a microvm on ike's host, a kernel of its
  own), `remote` (next month: a host of its own over WireGuard). One
  option apart; deploying.md has the steps for each, the remote one
  ready to follow.
- **ike speaks to the stripper over a unix socket or tcp,** the same
  bytes either way; a tcp address is an ip as written, never a name to
  look up. `nix/strip-unit.nix` is the one sandboxed instance all three
  run; `nix/strip-host.nix` serves it over tcp to ike's address alone
  (the socket's IP list and the firewall both); `nix/strip-microvm.nix`
  puts that in a microvm on a host-only /30.
- **New dependency, approved by lux** (option 1): microvm.nix (Astro,
  astro/microvm.nix, from 2022), pinned in `pins.json`, its host module
  imported by fog beside ike's.
- **Tested:** `ike_strip_tcp_SUITE` (ike over tcp, and nothing listening
  is "not kept, try again"); `checks.remote-strip`, two machines, the
  stripper on one answering ike's and refusing its own; `checks.microvm`
  builds the microvm's runner. *Not tested:* booting the microvm, which
  needs kvm inside the test's vm; its first boot is on ike's host.

## The fetcher, and tweets (lux, 2026-11-18)

- **Uploads from a link,** by accounts only, from `/upload` ("or from a
  link"), thirty an hour each (hazard N7). The link goes to the fetcher;
  each file it brings is stripped as any upload (invariant 6) and kept as
  the account's, private or signed as asked; its meta gets where it came
  from, who made it, and what they said there (`meta.source`, `artist`,
  `artist_url`, `said`, migration 0028), shown on its page; the card made
  of it takes the words as its first commentary, as Danbooru copies an
  artist's commentary. One file leads to its meta.
- **The fetcher** (`fetch/ike-fetch`, Python's standard library, no new
  dependency) is a unit of its own, once per link, behind a unix socket
  (`services.ike.fetch.enable`, off unless asked). Invariant 7 in code: it
  resolves each name itself and refuses one with any address that is not
  public (loopback, private, link-local, CGNAT, ULA, multicast,
  reserved), connects to the address it checked (no second lookup),
  checks again at every redirect (three at most), talks https only and
  only to a site's own hosts (X's: the embeds' endpoint, `pbs.twimg.com`,
  `video.twimg.com`), and caps sizes (the stripper's) and times (20 s a
  request, 90 s a link). And systemd: the unit is denied those ranges by
  address too, and reaches DNS through nscd's socket.
- **Sandbox, for now** (lux: the microvm does not run on a CCX13): ike is
  accounts only, so the links are accounts'; the fetcher's own checks and
  systemd's deny list are what keep invariant 7, wherever it runs. A host
  of its own (deploying.md's `remote`) would add its own address to the
  world and another machine between; the same socket protocol makes that
  a move, not a rewrite.
- **Tweets, as Danbooru reads them:** the original image (`name=orig`)
  or the best mp4; the source as `https://x.com/<user>/status/<id>`; the
  author's name and page; the text as ikext commentary, its short links
  given their addresses back, hashtags and mentions made links (they do
  lead to twitter here), the media's own link dropped. Read from the
  endpoint X's own embeds read (`cdn.syndication.twimg.com/tweet-result`),
  which needs no account. *Not reached that way:* protected tweets, and
  some marked sensitive; Danbooru's way (X's GraphQL with an account's
  cookies) would reach them, behind the same fetcher, with the account
  lux offered (Q47).
- **Tested:** `ike_fetch_SUITE` against a stand-in for X; invariant 7's
  test (no longer a tripwire) runs the built fetcher at a stand-in whose
  tweets name a link-local, a private, a foreign and a canary's address,
  or redirect to it, and the canary counts no visit; the VM test reads
  the unit's deny list; and `test/live/x-tweet.sh`, by hand on theorem,
  fetches lux's tweet from X itself and checks its words, author and
  image to the byte (it passed 2026-11-18).

## The search bar stays, and tags lead to the wiki

lux, 2026-11-19: a search bar the booru keeps while a card is looked at,
+ and - beside each of a card's tags, and the tags linked into the wiki.

- **Where the search is kept:** in the link. A search's results lead to
  `/booru/N?tags=...`, and that card is made per request (by the reader,
  with the renderer's own code), its bar holding the search; without a
  search the card is its file, as before. Caddy leaves a request with
  `tags` in its query to ike. So it needs no script, and no cookie: the
  bar keeps what the address keeps (back and forward included), and a
  card opened from elsewhere starts with an empty bar.
- **+ and -:** + puts the tag in the search (on, if it was taken off);
  - takes it out if it is in it, and otherwise leaves out the cards that
  have it, as a minus does (Danbooru's two buttons). Each is a link to
  the search it makes.
- **Tags lead to their wiki page**, on the card and in its revisions; a
  tag's page (or the page offered for one with none yet, now a 200
  rather than a 404) leads to the cards that have it. A name no page can
  have (one starting with a dot) still leads to its search.
- **Not cached:** a card made per request reads the database each time,
  as search does (N6's cache is still owed for both).
