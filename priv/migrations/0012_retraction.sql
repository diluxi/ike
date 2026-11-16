-- retraction (lux, 2026-11-16): a poster trashes their own post with the
-- password they gave when posting, as vichan has it. kept is a salt and
-- a slow hash of it, per post, never the password: the same password on
-- two posts leaves nothing in common. retracted says the trash was the
-- poster's, not a moderator's
ALTER TABLE post ADD COLUMN password BLOB CHECK (password IS NULL OR length(password) = 48);
ALTER TABLE post ADD COLUMN retracted INTEGER NOT NULL DEFAULT 0
	CHECK (retracted IN (0, 1) AND (retracted = 0 OR state = 2));
