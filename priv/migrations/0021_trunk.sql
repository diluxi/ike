-- the trunk (lux, 2026-11-17): every asset has a meta, what is known of
-- it beyond its bytes, made when it is first uploaded. its owner is that
-- upload's actor (the anonymous one for nobody's). a meta is public
-- unless its owner, an account, made it private: public ones are listed
-- in /trunk and their files are on the media origin; a private one is
-- shown only to its owner and moderators (invariant 10)
CREATE TABLE meta (
	asset BLOB PRIMARY KEY REFERENCES asset (hash),
	owner INTEGER NOT NULL REFERENCES actor (id),
	time INTEGER NOT NULL,
	private INTEGER NOT NULL DEFAULT 0 CHECK (private IN (0, 1))
) STRICT, WITHOUT ROWID;

CREATE INDEX meta_time ON meta (time);

-- every asset there now, owned by its first upload's actor. what was
-- staged and never posted was private by invariant 10 as it stood, and
-- stays so; the rest was shown in a post already
INSERT INTO meta (asset, owner, time, private)
	SELECT u.asset, u.actor, u.time,
		NOT EXISTS (SELECT 1 FROM upload v WHERE v.asset = u.asset AND v.posted IS NOT NULL)
	FROM upload u
	WHERE u.id = (SELECT min(id) FROM upload w WHERE w.asset = u.asset);

DROP VIEW asset_reference;
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
