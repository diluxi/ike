-- tag names beyond ascii (lux, 2026-11-18: copyright:ガールズバンドクライ):
-- ascii is the closed set it was; any other character too, but space
-- and the like, which ike_tag refuses, the check keeping what it can.
-- sqlite alters no check, so the table is made again, its rows and ids
-- kept; booru_tag's keys wait for the end of the migration to be checked
PRAGMA defer_foreign_keys = ON;

CREATE TEMP TABLE tag_kept AS SELECT id, name FROM tag;
DROP TABLE tag;
CREATE TABLE tag (
	id INTEGER PRIMARY KEY,
	name TEXT NOT NULL UNIQUE
		CHECK (length(name) BETWEEN 1 AND 64
			AND name NOT GLOB '*[A-Z]*'
			AND instr(name, ' ') = 0 AND instr(name, char(9)) = 0
			AND instr(name, char(10)) = 0 AND instr(name, char(13)) = 0
			AND substr(name, 1, 1) NOT IN ('-', '~', '*'))
) STRICT;
INSERT INTO tag (id, name) SELECT id, name FROM tag_kept;
DROP TABLE tag_kept;

CREATE TRIGGER tag_searched AFTER INSERT ON tag BEGIN
	INSERT INTO tag_search (rowid, name) VALUES (new.id, new.name);
END;
