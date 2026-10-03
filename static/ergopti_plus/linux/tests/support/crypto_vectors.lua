--- tests/support/crypto_vectors.lua
--- Loads independent SHA-256 byte vectors shared by native and portable tests.
--- Expected hashes are standard vectors or independently computed with hashlib.
local json = require("json")
local file = assert(io.open("../_shared/data/crypto/sha256_vectors.json", "rb"))
local rows = assert(json.decode(file:read("*a")))
assert(file:close())
assert(#rows == 18, "shared SHA-256 corpus must be complete")
for _, row in ipairs(rows) do
	assert(#row.input_hex % 2 == 0 and not row.input_hex:find("[^0-9a-f]"))
	local bytes = row.input_hex:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end)
	row.input = string.rep(bytes, row["repeat"])
	assert(#row.sha256 == 64 and not row.sha256:find("[^0-9a-f]"))
end
return rows
