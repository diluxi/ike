-- lux's words (2026-11-16): nothing is erased but by a purge. "delete"
-- becomes trash: out of every view but moderators', kept, and put back
-- by restore. no hold, no purge after it. post.purge_at keeps its name,
-- since sqlite alters no check, and now says when the post was trashed

-- the log learns the word
CREATE TABLE action_new (
	entry INTEGER PRIMARY KEY REFERENCES post (id),
	actor INTEGER REFERENCES actor (id),
	role TEXT NOT NULL
		CHECK (role IN ('admin', 'moderator', 'janitor', 'system')),
	kind TEXT NOT NULL CHECK (kind IN ('hide', 'unhide', 'trash',
		'restore', 'purge', 'ban', 'unban', 'lock', 'unlock',
		'block', 'unblock', 'purge_image')),
	post INTEGER,
	account INTEGER REFERENCES actor (id),
	board INTEGER REFERENCES board (id),
	CHECK ((role = 'system') = (actor IS NULL))
) STRICT;
INSERT INTO action_new
	SELECT entry, actor, role, CASE kind WHEN 'delete' THEN 'trash' ELSE kind END,
		post, account, board
	FROM action;
DROP TABLE action;
ALTER TABLE action_new RENAME TO action;

DROP INDEX post_held;
CREATE INDEX post_trashed ON post (purge_at) WHERE state = 2;
