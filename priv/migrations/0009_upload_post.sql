-- the post an upload went into, by number: how a moderator reaches the
-- account behind an unsigned image (planning, Moderation: image uploads
-- need an account so that it can be suspended), and what goes with the
-- post when it is purged. a number, not a key: it outlives what it names
ALTER TABLE upload ADD COLUMN post INTEGER;
CREATE INDEX upload_post ON upload (post) WHERE post IS NOT NULL;
