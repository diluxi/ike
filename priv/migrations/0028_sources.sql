-- what a fetched upload came from (lux, 2026-11-18; as Danbooru keeps a
-- post's source and its artist's commentary): the link it was fetched
-- from, who made it and where they are, and what they said there, in
-- ikext. a meta's, so the same bytes from elsewhere say their own; its
-- card takes the commentary when it is made
ALTER TABLE meta ADD COLUMN source TEXT;
ALTER TABLE meta ADD COLUMN artist TEXT;
ALTER TABLE meta ADD COLUMN artist_url TEXT;
ALTER TABLE meta ADD COLUMN said TEXT;
