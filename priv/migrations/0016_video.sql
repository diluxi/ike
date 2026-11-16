-- video (M2, lux 2026-11-16: ffmpeg): webm and mp4, remuxed without
-- metadata. asset.type's check names images only and sqlite alters no
-- check, so the format moves to a column of its own; type is kept for
-- images and no longer read
ALTER TABLE asset ADD COLUMN format TEXT
	CHECK (format IN ('jpeg', 'png', 'webp', 'webm', 'mp4'));
UPDATE asset SET format = type;
