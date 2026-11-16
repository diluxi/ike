-- the booru (M2): an entry, ##N, is a curated record over an append-only
-- list of asset versions (planning, Model). its own number sequence. one
-- entry per asset: two posts of the same file share it. a version whose
-- asset was purged stays, empty: a gap (planning line 26)
CREATE TABLE booru (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	time INTEGER NOT NULL,
	-- 0 shown, 1 hidden, 2 trashed, as posts
	state INTEGER NOT NULL DEFAULT 0 CHECK (state IN (0, 1, 2))
) STRICT;

CREATE TABLE booru_version (
	booru INTEGER NOT NULL REFERENCES booru (id),
	position INTEGER NOT NULL CHECK (position >= 0),
	asset BLOB REFERENCES asset (hash),
	time INTEGER NOT NULL,
	PRIMARY KEY (booru, position)
) STRICT;

CREATE UNIQUE INDEX booru_version_asset ON booru_version (asset) WHERE asset IS NOT NULL;

-- an entry as pages show it: shown, with its newest version's asset
-- (null where that version was purged)
CREATE VIEW shown_entry AS
	SELECT b.id, b.time, v.position, v.asset
	FROM booru b JOIN booru_version v ON v.booru = b.id
	WHERE b.state = 0
	AND v.position = (SELECT max(position) FROM booru_version WHERE booru = b.id);

-- what a moderator did to an entry, beside what was done to a post
ALTER TABLE action ADD COLUMN booru INTEGER;

DROP VIEW asset_reference;
CREATE VIEW asset_reference (asset, via) AS
	SELECT asset, 'post.asset' FROM post WHERE asset IS NOT NULL
	UNION ALL
	SELECT asset, 'post_image.asset' FROM post_image WHERE asset IS NOT NULL
	UNION ALL
	SELECT asset, 'upload.asset' FROM upload WHERE posted IS NULL
	UNION ALL
	SELECT asset, 'booru_version.asset' FROM booru_version WHERE asset IS NOT NULL;
