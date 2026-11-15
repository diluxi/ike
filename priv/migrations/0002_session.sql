-- who is logged in, so that a restart logs nobody out. a session is named
-- by the sha-256 of what its cookie holds, so that reading this table
-- gives nobody a session. snapshots are taken without its rows
CREATE TABLE session (
	hash BLOB PRIMARY KEY CHECK (length(hash) = 32),
	actor INTEGER NOT NULL REFERENCES actor (id),
	csrf TEXT NOT NULL,
	-- unix seconds
	expires INTEGER NOT NULL
) STRICT, WITHOUT ROWID;
