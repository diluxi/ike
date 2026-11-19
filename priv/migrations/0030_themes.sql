-- themes (lux, 2026-11-19): no stylesheet is static; each is a theme a
-- moderator edits at /mod/themes, one of them the site's. a theme's name
-- is part of a file's on the media origin, so it is a closed set. its
-- changes are kept, with who made them
CREATE TABLE theme (
	name TEXT PRIMARY KEY
		CHECK (length(name) BETWEEN 1 AND 32 AND name NOT GLOB '*[^a-z0-9-]*'),
	css TEXT NOT NULL CHECK (length(css) <= 262144),
	active INTEGER NOT NULL DEFAULT 0 CHECK (active IN (0, 1))
) STRICT;

CREATE UNIQUE INDEX theme_active ON theme (active) WHERE active = 1;

CREATE TABLE theme_change (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	theme TEXT NOT NULL,
	actor INTEGER REFERENCES actor (id),
	time INTEGER NOT NULL,
	what TEXT NOT NULL CHECK (what IN ('seeded', 'edited', 'used', 'dropped')),
	css TEXT
) STRICT;
