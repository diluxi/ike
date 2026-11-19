-- kinds of tag (lux, 2026-11-19): a tag is a kind and a name, written
-- kind/name, so that canon/spider-man and character/spider-man are two
-- tags and two pages. no hierarchy: a kind is one of a closed set. a
-- name alone is the one tag by that name while there is only one. info
-- is no kind of tag: it is the wiki's every page that is not a tag's.
-- what ike tags by what an asset is, is meta; every other tag so far is
-- a description. sqlite alters no unique constraint, so the tables are
-- made again, their rows and ids kept
PRAGMA defer_foreign_keys = ON;

CREATE TEMP TABLE tag_kept AS SELECT id, name FROM tag;
DROP TABLE tag;
CREATE TABLE tag (
	id INTEGER PRIMARY KEY,
	kind TEXT NOT NULL DEFAULT 'description'
		CHECK (kind IN ('artist', 'character', 'canon', 'description', 'meta')),
	name TEXT NOT NULL
		CHECK (length(name) BETWEEN 1 AND 64
			AND name NOT GLOB '*[A-Z]*'
			AND instr(name, ' ') = 0 AND instr(name, char(9)) = 0
			AND instr(name, char(10)) = 0 AND instr(name, char(13)) = 0
			AND instr(name, '/') = 0
			AND substr(name, 1, 1) NOT IN ('-', '~', '*')),
	UNIQUE (kind, name)
) STRICT;
INSERT INTO tag (id, kind, name) SELECT id,
	CASE WHEN name IN ('image', 'raster', 'vector', 'animation', 'video', 'audio', 'font')
		THEN 'meta' ELSE 'description' END,
	name FROM tag_kept;
DROP TABLE tag_kept;
CREATE INDEX tag_name ON tag (name);

CREATE TRIGGER tag_searched AFTER INSERT ON tag BEGIN
	INSERT INTO tag_search (rowid, name) VALUES (new.id, new.name);
END;

-- a page is a kind and a name too, and its name as written is both,
-- kind/name: what [[kind/name]] and its address say. a page by a tag's
-- name is that tag's page; any other is info
CREATE TEMP TABLE page_kept AS SELECT name, thread FROM page;
DROP TABLE page;
CREATE TABLE page (
	name TEXT PRIMARY KEY CHECK (name = kind || '/' || bare),
	kind TEXT NOT NULL
		CHECK (kind IN ('artist', 'character', 'canon', 'description', 'meta', 'info')),
	bare TEXT NOT NULL
		CHECK (length(bare) BETWEEN 1 AND 64 AND instr(bare, '/') = 0
			AND instr(bare, ' ') = 0 AND substr(bare, 1, 1) NOT IN ('-', '~', '*', '.')),
	thread INTEGER NOT NULL UNIQUE REFERENCES thread (root)
) STRICT;
INSERT INTO page (name, kind, bare, thread)
	SELECT coalesce((SELECT t.kind FROM tag t WHERE t.name = k.name), 'info') || '/' || k.name,
		coalesce((SELECT t.kind FROM tag t WHERE t.name = k.name), 'info'),
		k.name, k.thread
	FROM page_kept k;
DROP TABLE page_kept;
CREATE INDEX page_bare ON page (bare);
