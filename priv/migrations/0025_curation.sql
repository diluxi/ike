-- curation (lux, 2026-11-17): a meta is tagged on its page and posted to
-- the booru, which makes it a curation (an entry). a meta and a curation
-- have a comment thread, on the board trunk, which is attached: it has no
-- page of its own, its threads are read where they belong. the meta's
-- thread becomes its curation's. tag and commentary changes are revisions
-- in it, as a wiki page's edits are
ALTER TABLE board ADD COLUMN attached INTEGER NOT NULL DEFAULT 0 CHECK (attached IN (0, 1));
-- accounts only, until anonymous comments are wanted there
INSERT INTO board (name, title, locked, attached) VALUES ('trunk', 'the trunk', 1, 1)
	ON CONFLICT (name) DO UPDATE SET attached = 1, locked = 1;

ALTER TABLE meta ADD COLUMN thread INTEGER REFERENCES post (id);
ALTER TABLE booru ADD COLUMN thread INTEGER REFERENCES post (id);
-- the meta it was curated from, and whose it is: its meta's owner, by
-- name if the meta was signed
ALTER TABLE booru ADD COLUMN meta INTEGER REFERENCES meta (id);
ALTER TABLE booru ADD COLUMN owner INTEGER REFERENCES actor (id);
ALTER TABLE booru ADD COLUMN signed INTEGER NOT NULL DEFAULT 0 CHECK (signed IN (0, 1));

-- what is shown to everyone. an attached thread is shown as what it
-- belongs to is: a curation's while the curation is shown, else a
-- meta's while the meta is public and shown. a private or taken down
-- meta's thread is in no page made for everyone, and is read on the
-- meta's own page, by those who may see the meta. as on the wiki, an
-- attached thread outlives its first post
DROP VIEW shown;
CREATE VIEW shown AS
	SELECT p.id, p.thread, p.actor, p.time, p.parent, p.asset, p.body, p.asset_gone
	FROM post p JOIN post r ON r.id = p.thread
	LEFT JOIN thread t ON t.root = p.thread LEFT JOIN board b ON b.id = t.board
	WHERE p.state = 0
	AND (r.state = 0 OR coalesce(b.wiki, 0) = 1 OR coalesce(b.attached, 0) = 1)
	AND (coalesce(b.attached, 0) = 0
		OR EXISTS (SELECT 1 FROM booru e WHERE e.thread = p.thread AND e.state = 0)
		OR (NOT EXISTS (SELECT 1 FROM booru e WHERE e.thread = p.thread)
			AND EXISTS (SELECT 1 FROM meta m WHERE m.thread = p.thread
				AND m.private = 0 AND m.state = 0)));
