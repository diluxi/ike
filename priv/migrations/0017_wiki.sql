-- the wiki (M3, before launch on lux's word): a page is the first post of
-- its own thread on the board wiki; an edit is a reply carrying the
-- page's whole new text, marked a revision, with the revision it was made
-- on (planning, Model). other replies are the page's discussion. a page
-- is a name, kept here only to find its thread
ALTER TABLE board ADD COLUMN wiki INTEGER NOT NULL DEFAULT 0 CHECK (wiki IN (0, 1));
INSERT INTO board (name, title, wiki) VALUES ('wiki', 'the wiki', 1)
	ON CONFLICT (name) DO UPDATE SET wiki = 1;

ALTER TABLE post ADD COLUMN revision INTEGER NOT NULL DEFAULT 0 CHECK (revision IN (0, 1));
ALTER TABLE post ADD COLUMN base INTEGER;

-- a name as tags have them, and not starting with a dot: it is a file's
CREATE TABLE page (
	name TEXT PRIMARY KEY
		CHECK (length(name) BETWEEN 1 AND 64 AND name NOT GLOB '*[^a-z0-9_()!?:.''-]*'
			AND substr(name, 1, 1) NOT IN ('-', '~', '*', '.')),
	thread INTEGER NOT NULL UNIQUE REFERENCES thread (root)
) STRICT;
