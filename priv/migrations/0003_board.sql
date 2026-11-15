-- boards. a new one is locked: only accounts post on it (hazard a4).
-- which boards exist is the configuration's; whether one is locked is a
-- moderator's, so it lives here
CREATE TABLE board (
	id INTEGER PRIMARY KEY,
	-- as in /board/<name> and >>>/<name>/N
	name TEXT NOT NULL UNIQUE
		CHECK (length(name) BETWEEN 1 AND 16 AND name NOT GLOB '*[^a-z0-9]*'),
	title TEXT NOT NULL,
	locked INTEGER NOT NULL DEFAULT 1 CHECK (locked IN (0, 1))
) STRICT;

-- a thread need not be on a board: it may come to hang off a booru post
-- or a wiki page instead
ALTER TABLE thread ADD COLUMN board INTEGER REFERENCES board (id);
CREATE INDEX thread_board ON thread (board) WHERE board IS NOT NULL;
