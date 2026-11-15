-- roles are ranked: janitor < moderator < admin. a janitor keeps the
-- boards it looks after beside its session, space-separated
ALTER TABLE session ADD COLUMN boards TEXT;

-- the rank an account had at its last login, 0 for none: what it takes
-- to ban it. an account promoted since, or not logged in since this
-- column came, counts as unranked until it logs in
ALTER TABLE actor ADD COLUMN rank INTEGER NOT NULL DEFAULT 0
	CHECK (rank BETWEEN 0 AND 3);
