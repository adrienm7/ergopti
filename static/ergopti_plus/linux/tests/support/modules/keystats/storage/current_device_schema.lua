-- Exact sqlite_master text for the shipped devices schema.
return [==[CREATE TABLE devices (
	device_id                  TEXT PRIMARY KEY,
	name                       TEXT NOT NULL,
	os                         TEXT NOT NULL CHECK (os IN ('darwin','windows','linux')),
	os_version                 TEXT,
	host_signature             TEXT NOT NULL,
	created_at                 TEXT NOT NULL,
	updated_at                 TEXT NOT NULL,
	-- Watermark of the data.sql file under by_device/<device_id>/ that the
	-- LOCAL db.sqlite has already ingested. Tracked per device because the
	-- local sqlite cumulates events from every device's data.sql.
	imported_data_sql_size     INTEGER NOT NULL DEFAULT 0,
	imported_data_sql_sha256   TEXT
)]==] .. "\n"
