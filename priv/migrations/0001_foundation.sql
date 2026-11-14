-- the foundation: actors, the global post sequence, threads, assets as far
-- as a post can name one, reverse links and the reachability view

-- kind tags a sum, and the checks tie each kind to the columns it carries.
-- remote and board carry nothing yet
CREATE TABLE actor (
	id INTEGER PRIMARY KEY,
	kind TEXT NOT NULL
		CHECK (kind IN ('anonymous', 'local', 'remote', 'board')),
	issuer TEXT,
	subject TEXT,
	CHECK ((kind = 'local') = (issuer IS NOT NULL)),
	CHECK ((issuer IS NULL) = (subject IS NULL))
) STRICT;

-- anonymous is one actor shared by everyone who is nobody
CREATE UNIQUE INDEX actor_anonymous ON actor (kind) WHERE kind = 'anonymous';
CREATE UNIQUE INDEX actor_local ON actor (issuer, subject)
	WHERE kind = 'local';
INSERT INTO actor (id, kind) VALUES (1, 'anonymous');

-- identity is the sha-256 of the stored bytes
CREATE TABLE asset (
	hash BLOB PRIMARY KEY CHECK (length(hash) = 32)
) STRICT, WITHOUT ROWID;

-- a thread is named by its root's >>N. the root need not live in the
-- thread: a promoted reply stays in its home thread
CREATE TABLE thread (
	root INTEGER PRIMARY KEY
		REFERENCES post (id) DEFERRABLE INITIALLY DEFERRED
) STRICT;

-- id is >>N. autoincrement, so that a number is never handed out twice,
-- not even after its row is gone. a change is a new post
CREATE TABLE post (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	-- the home thread; an op's is its own id, hence the deferred keys
	thread INTEGER NOT NULL
		REFERENCES thread (root) DEFERRABLE INITIALLY DEFERRED,
	actor INTEGER NOT NULL REFERENCES actor (id),
	-- seconds since the epoch, utc, set by the writer
	time INTEGER NOT NULL,
	parent INTEGER REFERENCES post (id),
	asset BLOB REFERENCES asset (hash),
	body TEXT NOT NULL
) STRICT;

CREATE INDEX post_thread ON post (thread, id);
CREATE INDEX post_parent ON post (parent) WHERE parent IS NOT NULL;
CREATE INDEX post_asset ON post (asset) WHERE asset IS NOT NULL;

-- reverse links: who mentions >>N, ##N or [[name]]. exactly one target
-- per row. targets are weak, so they are not foreign keys
CREATE TABLE link (
	source INTEGER NOT NULL REFERENCES post (id) ON DELETE CASCADE,
	post INTEGER,
	booru INTEGER,
	name TEXT,
	CHECK ((post IS NOT NULL) + (booru IS NOT NULL) + (name IS NOT NULL) = 1)
) STRICT;

CREATE UNIQUE INDEX link_post ON link (post, source) WHERE post IS NOT NULL;
CREATE UNIQUE INDEX link_booru ON link (booru, source)
	WHERE booru IS NOT NULL;
CREATE UNIQUE INDEX link_name ON link (name, source) WHERE name IS NOT NULL;
CREATE INDEX link_source ON link (source);

-- reachability (hazard g6, invariant 9): every strong reference to an
-- asset, one select per referencing column, labelled 'table.column'
CREATE VIEW asset_reference (asset, via) AS
	SELECT asset, 'post.asset' FROM post WHERE asset IS NOT NULL;
