-- hashes no upload may have again (planning, Moderation: hash ban and
-- purge; hazard G3): a stored hash, or the hash of bytes as they came.
-- a hash, not a reference: it outlives what it names, which is the point
CREATE TABLE blocklist (
	hash BLOB PRIMARY KEY CHECK (length(hash) = 32),
	time INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

-- a post whose image was purged keeps its text and says the image is
-- gone, in the words every other taken-down thing uses (hazard G5)
ALTER TABLE post ADD COLUMN asset_gone INTEGER NOT NULL DEFAULT 0
	CHECK (asset_gone IN (0, 1) AND (asset_gone = 0 OR asset IS NULL));

DROP VIEW shown;
CREATE VIEW shown AS
	SELECT p.id, p.thread, p.actor, p.time, p.parent, p.asset, p.body, p.asset_gone
	FROM post p JOIN post r ON r.id = p.thread
	WHERE p.state = 0 AND r.state = 0;

-- the log learns the image's rungs
CREATE TABLE action_new (
	entry INTEGER PRIMARY KEY REFERENCES post (id),
	actor INTEGER REFERENCES actor (id),
	role TEXT NOT NULL
		CHECK (role IN ('admin', 'moderator', 'janitor', 'system')),
	kind TEXT NOT NULL CHECK (kind IN ('hide', 'unhide', 'delete',
		'restore', 'purge', 'ban', 'unban', 'lock', 'unlock',
		'block', 'unblock', 'purge_image')),
	post INTEGER,
	account INTEGER REFERENCES actor (id),
	board INTEGER REFERENCES board (id),
	CHECK ((role = 'system') = (actor IS NULL))
) STRICT;
INSERT INTO action_new SELECT * FROM action;
DROP TABLE action;
ALTER TABLE action_new RENAME TO action;
