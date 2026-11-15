# ike — status

Updated 2026-11-15. Milestone: **M0 Foundation**, all eight steps
written; waiting on lux to merge and to answer.

## Done

- **Steps 1 to 3** and lux's answers, merged into dev (`phi/charter`,
  `phi/skeleton`, `phi/schema`, `phi/answers`, `phi/ci`). CI runs on dev
  and passes.
- **Step 4** (`phi/writer`, on dev): `ike_writer`, the one process with
  a writable connection; `reader()` and `writer()` as types; typed ids;
  query timeouts.
- **Step 5** (`phi/render`, on `phi/writer`): HTML as a tree; thread
  pages and the index as files renamed into place; Cowboy serving them
  when nothing else does; the Caddy virtual host in the module.
- **Step 6** (`phi/login`, on `phi/render`): the OIDC client (code flow,
  PKCE, state, nonce, RS256 against the JWKS); sessions and CSRF tokens;
  `/login`, `/logout`, `/new`, `/t/N/reply` as plain forms; a handler
  that forgets every request's address; `ike_login_SUITE` against a mock
  provider.
- **Step 7** (`phi/backup`, on `phi/login`): daily snapshots by the
  writer, seven kept; `ike_backup_SUITE` posts, loses everything,
  restores and compares rows and page bytes.
- **Step 8** (`phi/invariants`, on `phi/backup`): `ike_invariant_SUITE`,
  one case per invariant. Six test what M0 has; five are tripwires for
  what it lacks (decisions.md, Invariant tests).

M0's exit sentence, "a logged-in POST writes a row and regenerates a
page the web server serves, and a restore from backup reproduces it", is
`ike_login_SUITE` and `ike_backup_SUITE` over HTTP, and the VM test for
Caddy serving the page files. No test logs in *through Caddy*: the VM
has no provider.

## Checks

`nix-build -A checks` (release, tests with xref and erlfmt, eqWAlizer,
the module in a VM) was run on the tips of `phi/login`, `phi/backup` and
`phi/invariants`. `phi/writer` and `phi/render` were checked with the
VM test and the host's rebar3 and eqWAlizer as they were written, not
with the full set at their final tips.

## Next

Nothing in M0. M1 does not start until lux says so.

## Blocked on lux

- **Review and merge** `phi/writer` → `phi/render` → `phi/login` →
  `phi/backup` → `phi/invariants`, in that order; each is stacked on the
  one before.
- **Questions** (`questions.md`): Q7 the Authelia client and ike's host
  name; Q8 retention; Q9 whether the renderer may write its own files
  under invariant 3; Q10 how an account's post is shown; Q11 whether
  tripwires will do for the invariants M0 has no subject for; Q12
  sessions across restarts; Q5 whether the repository is public; C3 and
  Q3 before M1's migration.
- **Wording in lux's documents:** invariant 8 and the blocklist, nginx in
  planning.md.
- **Not committed, as asked:** `docs/planning.md`, `docs/hazards.md`,
  `docs/fog.md`. `phi.md` and the readme point at the first two.
- **The cert:** as before; fog's `lemma/certs/phi.asc` lacks the signing
  cert used here, which matters once lemma0 should accept these commits.
