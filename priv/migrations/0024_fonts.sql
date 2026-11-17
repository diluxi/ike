-- fonts (lux, 2026-11-17): ttf, otf, woff, woff2, by accounts only. a
-- format's check cannot be widened in place, so what a file is moves
-- to filetype, whose check asks only for a name's shape: the closed set
-- is ike_strip's, and the next kind of file (svg, meshes) needs no
-- migration for it. format is kept for what was there, no longer read
ALTER TABLE asset ADD COLUMN filetype TEXT
	CHECK (filetype IS NULL OR (length(filetype) BETWEEN 1 AND 8 AND filetype NOT GLOB '*[^a-z0-9]*'));
UPDATE asset SET filetype = format;

-- a font's family, and its variable axes ("wght 100 400 900", one a
-- line), as the stripper read them: what the font is, so the asset's
ALTER TABLE asset ADD COLUMN family TEXT;
ALTER TABLE asset ADD COLUMN axes TEXT;

-- what a font said of itself beyond its names (credits, license,
-- vendor, a woff's metadata), taken out of the stored file so that it
-- is no part of the hash, and kept with the upload that brought it, as
-- danbooru keeps an artist's commentary with a post
ALTER TABLE upload ADD COLUMN commentary TEXT;
