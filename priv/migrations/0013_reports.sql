-- reports (lux, 2026-11-16, as vichan and tinyboard have them): a post's
-- number and a reason, for moderators to look at. nothing of who sent
-- one is kept. done once a moderator has dismissed it
CREATE TABLE report (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	post INTEGER NOT NULL,
	reason TEXT NOT NULL CHECK (length(reason) BETWEEN 1 AND 1000),
	time INTEGER NOT NULL,
	done INTEGER NOT NULL DEFAULT 0 CHECK (done IN (0, 1))
) STRICT;

CREATE INDEX report_open ON report (id) WHERE done = 0;
