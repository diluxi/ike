-- metas are moderated as posts are (lux, 2026-11-17, Q40): shown,
-- hidden or trashed, each step logged and undone the same way. a meta
-- bears its owner's name when its upload was signed, else reads as
-- anonymous (Q42); existing ones were never signed
ALTER TABLE meta ADD COLUMN state INTEGER NOT NULL DEFAULT 0 CHECK (state IN (0, 1, 2));
ALTER TABLE meta ADD COLUMN signed INTEGER NOT NULL DEFAULT 0 CHECK (signed IN (0, 1));

-- what a moderator did to a meta, beside posts and entries: its asset's
-- hash, taken away if the asset is purged (invariant 8)
ALTER TABLE action ADD COLUMN meta BLOB;
