-- a post shows any number of images, in order (lux, 2026-11-16). each is
-- a row here; one whose asset was purged stays, empty, and says so
-- (hazard G5). post.asset and post.asset_gone are no longer written:
-- sqlite drops no column that is a foreign key, so they stay, empty
CREATE TABLE post_image (
	post INTEGER NOT NULL REFERENCES post (id) ON DELETE CASCADE,
	position INTEGER NOT NULL CHECK (position >= 0),
	asset BLOB REFERENCES asset (hash),
	gone INTEGER NOT NULL DEFAULT 0
		CHECK (gone IN (0, 1) AND (gone = 0) = (asset IS NOT NULL)),
	PRIMARY KEY (post, position)
) STRICT;

CREATE INDEX post_image_asset ON post_image (asset) WHERE asset IS NOT NULL;

INSERT INTO post_image (post, position, asset, gone)
	SELECT id, 0, asset, asset_gone FROM post
	WHERE asset IS NOT NULL OR asset_gone = 1;
UPDATE post SET asset = NULL, asset_gone = 0;

-- every strong reference to an asset (invariant 9)
DROP VIEW asset_reference;
CREATE VIEW asset_reference (asset, via) AS
	SELECT asset, 'post.asset' FROM post WHERE asset IS NOT NULL
	UNION ALL
	SELECT asset, 'post_image.asset' FROM post_image WHERE asset IS NOT NULL
	UNION ALL
	SELECT asset, 'upload.asset' FROM upload WHERE posted IS NULL;
