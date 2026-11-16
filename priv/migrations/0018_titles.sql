-- a post may have a title (lux, 2026-11-16); a wiki page's thread is
-- titled with the page's name
ALTER TABLE post ADD COLUMN title TEXT
	CHECK (title IS NULL OR length(title) BETWEEN 1 AND 100);
UPDATE post SET title = (SELECT name FROM page WHERE page.thread = post.id)
	WHERE id IN (SELECT thread FROM page);
