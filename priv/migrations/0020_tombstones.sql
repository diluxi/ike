-- a wiki page outlives its first revision (lux): on the board wiki, a
-- thread whose first post is out of view still shows its other posts,
-- the first left as a titled tombstone, and the next revision reads as
-- the page. a thread with nothing left in view is gone, as on any board
DROP VIEW shown;
CREATE VIEW shown AS
	SELECT p.id, p.thread, p.actor, p.time, p.parent, p.asset, p.body, p.asset_gone
	FROM post p JOIN post r ON r.id = p.thread
	WHERE p.state = 0 AND (r.state = 0 OR EXISTS (
		SELECT 1 FROM thread t JOIN board b ON b.id = t.board
		WHERE t.root = p.thread AND b.wiki = 1));
