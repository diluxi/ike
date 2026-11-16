-- tags (M2): a name, from a closed set of characters, kept once; an
-- entry's tags as a join table; and a history of who changed what, since
-- entries are a curated record (accounts tag directly until proposals,
-- M4; Q34)
CREATE TABLE tag (
	id INTEGER PRIMARY KEY,
	name TEXT NOT NULL UNIQUE
		CHECK (length(name) BETWEEN 1 AND 64 AND name NOT GLOB '*[^a-z0-9_()!?:.''-]*'
			AND substr(name, 1, 1) NOT IN ('-', '~', '*'))
) STRICT;

CREATE TABLE booru_tag (
	booru INTEGER NOT NULL REFERENCES booru (id),
	tag INTEGER NOT NULL REFERENCES tag (id),
	PRIMARY KEY (booru, tag)
) STRICT, WITHOUT ROWID;

CREATE INDEX booru_tag_tag ON booru_tag (tag, booru);

CREATE TABLE tag_change (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	booru INTEGER NOT NULL REFERENCES booru (id),
	actor INTEGER NOT NULL REFERENCES actor (id),
	time INTEGER NOT NULL,
	added TEXT NOT NULL,
	removed TEXT NOT NULL
) STRICT;

CREATE INDEX tag_change_booru ON tag_change (booru, id);

-- tag names by prefix: foo* in a search
CREATE VIRTUAL TABLE tag_search USING fts5 (
	name, content = 'tag', content_rowid = 'id', prefix = '2 3 4', tokenize = 'unicode61 tokenchars ''_()!?:.''''-'''
);

CREATE TRIGGER tag_searched AFTER INSERT ON tag BEGIN
	INSERT INTO tag_search (rowid, name) VALUES (new.id, new.name);
END;
