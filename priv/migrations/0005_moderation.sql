-- Moderation (planning.md, Moderation): what was done to a post, who is
-- suspended, and the log of both.

-- 0 shown, 1 hidden, 2 deleted and held until purge_at (unix seconds)
ALTER TABLE post ADD COLUMN state INTEGER NOT NULL DEFAULT 0
	CHECK (state IN (0, 1, 2));
ALTER TABLE post ADD COLUMN purge_at INTEGER
	CHECK ((purge_at IS NOT NULL) = (state = 2));
CREATE INDEX post_held ON post (purge_at) WHERE purge_at IS NOT NULL;

-- a post as pages may show it: neither it nor its thread's first post
-- taken down. every reader asks this, so that hidden, deleted and
-- purged look the same from outside (hazard G5)
CREATE VIEW shown AS
	SELECT p.id, p.thread, p.actor, p.time, p.parent, p.asset, p.body
	FROM post p JOIN post r ON r.id = p.thread
	WHERE p.state = 0 AND r.state = 0;

ALTER TABLE actor ADD COLUMN banned INTEGER NOT NULL DEFAULT 0
	CHECK (banned IN (0, 1) AND (banned = 0 OR kind = 'local'));

-- what the provider's groups made of the account at login (hazard I5)
ALTER TABLE session ADD COLUMN role TEXT
	CHECK (role IN ('admin', 'moderator', 'janitor'));

-- a board ike itself writes on, and nobody else
ALTER TABLE board ADD COLUMN log INTEGER NOT NULL DEFAULT 0
	CHECK (log IN (0, 1));
INSERT INTO board (name, title, log) VALUES ('mod', 'what moderators did', 1)
	ON CONFLICT (name) DO UPDATE SET log = 1;

-- one row beside each entry in the log. the entry is a post and says in
-- public what was done, to what, by which role and why; who it was is
-- only here. post is a number and not a key: it outlives what it names
CREATE TABLE action (
	entry INTEGER PRIMARY KEY REFERENCES post (id),
	-- null when ike acted by itself
	actor INTEGER REFERENCES actor (id),
	role TEXT NOT NULL
		CHECK (role IN ('admin', 'moderator', 'janitor', 'system')),
	kind TEXT NOT NULL CHECK (kind IN ('hide', 'unhide', 'delete',
		'restore', 'purge', 'ban', 'unban', 'lock', 'unlock')),
	post INTEGER,
	account INTEGER REFERENCES actor (id),
	board INTEGER REFERENCES board (id),
	CHECK ((role = 'system') = (actor IS NULL))
) STRICT;
