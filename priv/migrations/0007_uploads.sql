-- what the stripper measured of an asset. nullable only because sqlite
-- adds no column without a default; the writer always sets them
ALTER TABLE asset ADD COLUMN type TEXT CHECK (type IN ('jpeg', 'png', 'webp'));
ALTER TABLE asset ADD COLUMN width INTEGER CHECK (width > 0);
ALTER TABLE asset ADD COLUMN height INTEGER CHECK (height > 0);

-- an upload: an asset, as someone brought it (planning, Upload). staged
-- while posted is null, and then seen by its uploader only (invariant
-- 10). original is the sha-256 of the bytes as they came, before
-- stripping, for matching and bans (hazard p4); not a reference
CREATE TABLE upload (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	asset BLOB NOT NULL REFERENCES asset (hash),
	original BLOB NOT NULL CHECK (length(original) = 32),
	actor INTEGER NOT NULL REFERENCES actor (id),
	time INTEGER NOT NULL,
	posted INTEGER
) STRICT;

CREATE INDEX upload_staged ON upload (actor, id) WHERE posted IS NULL;
CREATE INDEX upload_asset ON upload (asset);

-- a staged upload keeps its asset alive; a posted one does through its
-- post (invariant 9)
DROP VIEW asset_reference;
CREATE VIEW asset_reference (asset, via) AS
	SELECT asset, 'post.asset' FROM post WHERE asset IS NOT NULL
	UNION ALL
	SELECT asset, 'upload.asset' FROM upload WHERE posted IS NULL;
