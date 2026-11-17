-- a meta is an owner's, not an asset's (lux, 2026-11-17, Q41): bytes
-- someone else holds privately get a meta of their own when uploaded
-- again, so that nothing says the other has them. an asset has at most
-- one public meta, and each owner at most one meta of it. metas are
-- numbered, as posts and entries are, and named by number
DROP VIEW asset_reference;

CREATE TABLE meta_new (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	asset BLOB NOT NULL REFERENCES asset (hash),
	owner INTEGER NOT NULL REFERENCES actor (id),
	time INTEGER NOT NULL,
	private INTEGER NOT NULL DEFAULT 0 CHECK (private IN (0, 1)),
	signed INTEGER NOT NULL DEFAULT 0 CHECK (signed IN (0, 1)),
	state INTEGER NOT NULL DEFAULT 0 CHECK (state IN (0, 1, 2)),
	UNIQUE (asset, owner)
) STRICT;

INSERT INTO meta_new (asset, owner, time, private, signed, state)
	SELECT asset, owner, time, private, signed, state FROM meta ORDER BY time, asset;

-- the log names a meta by its number now
ALTER TABLE action ADD COLUMN meta_id INTEGER;
UPDATE action SET meta_id = (SELECT m.id FROM meta_new m WHERE m.asset = action.meta)
	WHERE meta IS NOT NULL;
ALTER TABLE action DROP COLUMN meta;
ALTER TABLE action RENAME COLUMN meta_id TO meta;

DROP TABLE meta;
ALTER TABLE meta_new RENAME TO meta;

CREATE UNIQUE INDEX meta_public ON meta (asset) WHERE private = 0;
CREATE INDEX meta_time ON meta (time);

CREATE VIEW asset_reference (asset, via) AS
	SELECT asset, 'post.asset' FROM post WHERE asset IS NOT NULL
	UNION ALL
	SELECT asset, 'post_image.asset' FROM post_image WHERE asset IS NOT NULL
	UNION ALL
	SELECT asset, 'upload.asset' FROM upload WHERE posted IS NULL
	UNION ALL
	SELECT asset, 'booru_version.asset' FROM booru_version WHERE asset IS NOT NULL
	UNION ALL
	SELECT asset, 'meta.asset' FROM meta;
