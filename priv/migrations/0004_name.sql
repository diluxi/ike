-- what an account is called, as its provider says at each login. the one
-- thing about an actor that changes
ALTER TABLE actor ADD COLUMN name TEXT
	CHECK (name IS NULL OR kind = 'local');
