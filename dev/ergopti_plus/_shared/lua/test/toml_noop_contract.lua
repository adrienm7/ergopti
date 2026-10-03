--- _shared/lua/test/toml_noop_contract.lua

--- ==============================================================================
--- MODULE: TOML No-op Publication Contract
--- DESCRIPTION:
--- Replays the same typed operations as the native Windows suite. Unchanged
--- bytes must not be staged or replaced; source refusal remains a failure.
--- ==============================================================================

--- Registers cross-driver no-op and real-change persistence regressions.
--- @param helpers table Native driver test helpers.
--- @param fixture table Shared typed operation vectors.
return function(helpers, fixture)
	local Writer = require("toml_codec.writer")
	helpers.describe("TOML no-op persistence parity", function()
		for _, vector in ipairs(fixture.cases) do
			helpers.it("toml-noop-parity " .. vector.id, function()
				local disk, publications, stages = vector.input, 0, 0
				local row = { section = vector.section, key = vector.key,
					value = vector.value, delete = vector.delete }
				local original_open, original_rename, original_remove = io.open, os.rename, os.remove
				local staged
				io.open = function(_, mode)
					if mode == "r" then
						return { read = function() return disk end, close = function() return true end }
					end
					helpers.assert_eq(mode, "w")
					stages = stages + 1
					local handle = { close = function() return true end }
					handle.write = function(_, value) staged = value; return handle end
					return handle
				end
				os.rename = function() disk, publications = staged, publications + 1; return true end
				os.remove = function() return true end
				local ran, ok, detail, content = xpcall(function()
					return Writer.batch_write("/controlled/noop-parity.toml", { row })
				end, debug.traceback)
				io.open, os.rename, os.remove = original_open, original_rename, original_remove
				if not ran then error(ok, 0) end
				helpers.assert_eq(stages, vector.writes, "an unchanged image must not even be staged")
				helpers.assert_eq(ok, true, detail)
				helpers.assert_eq(publications, vector.writes, "only changed bytes need publication")
				helpers.assert_eq(content, disk, "the acknowledgement names the exact retained or committed bytes")
				if vector.writes == 0 then helpers.assert_eq(disk, vector.input) end
			end)
		end
		helpers.it("toml-noop-parity revalidates an unchanged source before acknowledgement", function()
			local reads, publications = 0, 0
			local ok = Writer.batch_write("/controlled/noop-stale.toml", {
				{ section = "demo", key = "value", value = 7 },
			}, {
				read_with_status = function()
					reads = reads + 1
					return reads == 1 and "[demo]\nvalue = 7\n" or "[demo]\nvalue = 8\n", "ok"
				end,
				write_if_unchanged = function() publications = publications + 1; return true end,
			})
			helpers.assert_eq(ok, false)
			helpers.assert_eq(publications, 0, "an unchanged old snapshot cannot acknowledge a newer source")
		end)
		helpers.it("toml-noop-parity refuses an unchanged source after the session fence", function()
			local path = "/controlled/noop-refused.toml"
			Writer.refuse_writes(path, "test session fence")
			local ok = Writer.batch_write(path, { { section = "demo", key = "value", value = 7 } }, {
				read_with_status = function() return "[demo]\nvalue = 7\n", "ok" end,
				write_if_unchanged = function() error("a fenced path must never publish") end,
			})
			helpers.assert_eq(ok, false)
		end)
	end)
end
