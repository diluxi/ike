-- what an asset is beyond its format, as the stripper found it: an
-- animated png, a video with sound. space-separated words, or empty.
-- an entry is tagged from it (lux: image, raster, animation, video,
-- audio; never a tag for an absence)
ALTER TABLE asset ADD COLUMN traits TEXT NOT NULL DEFAULT '';
