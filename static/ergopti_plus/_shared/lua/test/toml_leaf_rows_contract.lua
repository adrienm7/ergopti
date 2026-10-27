--- _shared/lua/test/toml_leaf_rows_contract.lua

--- Leaf operations reach the batch writer without losing neighbours or keys.
return function(helpers)
	local LeafRows = require("toml_codec.leaf_rows")
	local Writer = require("toml_codec.writer")
	local Codec = require("toml_codec")

	--- Applies planned rows to exact bytes through the real batch writer.
	--- @param content string|nil Source bytes; nil is an absent file.
	--- @param operations table Leaf operations.
	--- @return table decoded Candidate document.
	--- @return string candidate Candidate bytes.
	local function apply(content, operations)
		local rows = LeafRows.prepare(content or "", operations)
		local files = { read_with_status = function()
			if content == nil then return nil, "absent" end
			return content, "ok"
		end }
		local prepared, detail, candidate = Writer.prepare_batch("/virtual/leaf_rows.toml", rows, files)
		assert(prepared == true, tostring(detail))
		return Codec.decode(candidate), candidate
	end

	helpers.describe("toml leaf rows", function()
		-- A bare sibling written first creates the table header; an extension
		-- pack's identity must still be switchable under it afterwards.
		helpers.it("sets, updates and removes a quoted key under an existing table header", function()
			local source = "[hotstrings.groups]\nrolls = true\n\n[other]\nvalue = 1\n"
			local decoded, bytes = apply(source, {
				{ path = { "hotstrings", "groups", "ext:demo:rolls" }, value = true } })
			helpers.assert_eq(decoded.hotstrings.groups, { rolls = true, ["ext:demo:rolls"] = true })
			helpers.assert_eq(decoded.other.value, 1)
			helpers.assert_true(bytes:find('"ext:demo:rolls" = true', 1, true) ~= nil, "the identity is quoted")
			local updated, changed = apply(bytes, {
				{ path = { "hotstrings", "groups", "ext:demo:rolls" }, value = false } })
			helpers.assert_eq(updated.hotstrings.groups["ext:demo:rolls"], false)
			local _, count = changed:gsub("ext:demo:rolls", "")
			helpers.assert_eq(count, 1, "the quoted line is replaced, not duplicated")
			local removed, final = apply(changed, {
				{ path = { "hotstrings", "groups", "ext:demo:rolls" }, delete = true } })
			helpers.assert_eq(removed.hotstrings.groups, { rolls = true })
			helpers.assert_eq(final, source)
			helpers.assert_eq(#LeafRows.prepare(source, {
				{ path = { "hotstrings", "groups", "ext:demo:rolls" }, delete = true } }), 0,
				"an absent quoted key needs no removal")
		end)

		helpers.it("deletes nothing where the source holds a scalar instead of the leaf's table", function()
			local inline = '[hotstrings]\ndynamic = { date = false, keep = 1 }\n'
			helpers.assert_eq(#LeafRows.prepare(inline, {
				{ path = { "hotstrings", "dynamic", "date", "enabled" }, delete = true } }), 0,
				"an inline scalar is left as the file holds it")
			local header = "[hotstrings.dynamic]\ndate = false\n"
			local decoded, bytes = apply(header, {
				{ path = { "hotstrings", "dynamic", "date", "enabled" }, delete = true },
				{ path = { "hotstrings", "dynamic", "enabled" }, delete = true },
			})
			helpers.assert_eq(decoded.hotstrings.dynamic.date, false)
			helpers.assert_eq(bytes, header)
			helpers.assert_throws(function()
				LeafRows.prepare(inline, { { path = { "hotstrings", "dynamic", "date", "enabled" }, value = true } })
			end, "a write across a scalar is still refused")
		end)

	end)
end
