--- tests/unit/lib/test_toml_writer_transaction.lua

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
helpers.load_with_stubs("infra.logger")
-- Exercise the shared fallback transaction directly. The macOS wrapper now
-- injects adapters.file_system; adapter-specific source revalidation is covered
-- below with an explicit behavioral double.
local writer = helpers.load_with_stubs("toml_codec.writer")
local codec = helpers.load_with_stubs("toml_codec.codec")

local function with_file_stubs(open_fn, rename_fn, body)
	local original_open = io.open
	local original_rename = os.rename
	local original_remove = os.remove
	io.open = open_fn
	os.rename = rename_fn or function() return true end
	os.remove = function() return true end
	local ok, err = xpcall(body, debug.traceback)
	io.open = original_open
	os.rename = original_rename
	os.remove = original_remove
	if not ok then error(err, 0) end
end

local function minimal_data()
	return { sections_order = {}, sections = {} }
end

helpers.describe("toml_writer: exact transactional acknowledgement", function()
	helpers.it("write refuses to rename after a returned write failure", function()
		local renames = 0
		with_file_stubs(function(_, mode)
			helpers.assert_eq(mode, "w")
			return {
				write = function() return nil, "disk full", 28 end,
				close = function() return true end,
			}
		end, function()
			renames = renames + 1
			return true
		end, function()
			local ok = writer.write("/controlled/personal.toml", minimal_data())
			helpers.assert_eq(ok, false)
			helpers.assert_eq(renames, 0, "a failed staging write must never reach rename")
		end)
	end)

	helpers.it("write refuses to rename after a returned close failure", function()
		local renames = 0
		with_file_stubs(function()
			return {
				write = function(self) return self end,
				close = function() return false, "flush failed" end,
			}
		end, function()
			renames = renames + 1
			return true
		end, function()
			local ok = writer.write("/controlled/personal.toml", minimal_data())
			helpers.assert_eq(ok, false)
			helpers.assert_eq(renames, 0, "an uncommitted close must never reach rename")
		end)
	end)

	helpers.it("batch_write rejects malformed rows before any I/O (batch-write-row-validation)", function()
		local invalid_rows = {
			"not a row",
			{ section = nil, key = "value", value = "x" },
			{ section = "", key = "value", value = "x" },
			{ section = "script", key = nil, value = "x" },
			{ section = "script", key = "", value = "x" },
			{ section = "script", key = "value" },
			{ section = "script", key = "value", value = {} },
		}

		for index, row in ipairs(invalid_rows) do
			local reads = 0
			local writes = 0
			local adapter = {
				read_with_status = function()
					reads = reads + 1
					return nil, "absent"
				end,
				write = function()
					writes = writes + 1
					return true
				end,
			}
			local call_ok, wrote, err = pcall(writer.batch_write,
				"/controlled/config.toml", { row }, adapter)
			helpers.assert_eq(call_ok, true,
				"invalid row " .. index .. " must return a typed refusal, not raise")
			helpers.assert_eq(wrote, false)
			helpers.assert_true(type(err) == "string" and err ~= "")
			helpers.assert_eq(reads, 0, "validation must precede source acquisition")
			helpers.assert_eq(writes, 0, "invalid rows must never reach publication")
		end
	end)

	helpers.it("batch_write rejects duplicate logical rows before any I/O", function()
		local reads = 0
		local call_ok, wrote, err = pcall(writer.batch_write,
			"/controlled/config.toml", {
				{ section = "Script", key = "my-key", value = "first" },
				{ section = "script", key = "MY-KEY", value = "second" },
			}, {
				read_with_status = function()
					reads = reads + 1
					return nil, "absent"
				end,
				write = function() return true end,
			})
		helpers.assert_eq(call_ok, true)
		helpers.assert_eq(wrote, false)
		helpers.assert_true(type(err) == "string" and err ~= "")
		helpers.assert_eq(reads, 0, "duplicate rows must fail before reading the destination")
	end)

	helpers.it("batch_write updates a hyphenated key exactly once (batch-write-hyphenated-key)", function()
		local initial = "[script]\nmy-key = \"old\"\n"
		local captured
		local adapter = {
			read_with_status = function() return initial, "ok" end,
			write_if_unchanged = function(_path, content, expected_source)
				helpers.assert_eq(expected_source.status, "ok")
				helpers.assert_eq(expected_source.content, initial)
				captured = content
				return true
			end,
			write = function() error("classified publication must stay serialized") end,
		}
		local ok = writer.batch_write("/controlled/config.toml", {
			{ section = "script", key = "my-key", value = "new" },
		}, adapter)

		helpers.assert_eq(ok, true)
		local _, occurrences = captured:gsub("my%-key%s*=", "")
		helpers.assert_eq(occurrences, 1, "the existing key must be replaced, never appended")
		helpers.assert_contains(captured, 'my-key = "new"')
		helpers.assert_eq(captured:find('my-key = "old"', 1, true), nil)
		local decoded = codec.decode(captured)
		helpers.assert_true(type(decoded) == "table", "the published file must remain valid TOML")
		helpers.assert_eq(decoded.script["my-key"], "new")
	end)

	helpers.it("batch_write refuses to overwrite an unreadable existing source", function()
		local write_opens = 0
		with_file_stubs(function(candidate, mode)
			if mode == "r" then return nil, "Permission denied", 13 end
			if candidate == "/controlled/config.toml.tmp" then write_opens = write_opens + 1 end
			return nil, "must not stage"
		end, nil, function()
			local ok = writer.batch_write("/controlled/config.toml", {
				{ section = "features", key = "enabled", value = true },
			})
			helpers.assert_eq(ok, false)
			helpers.assert_eq(write_opens, 0, "EACCES is not a fresh config")
		end)
	end)

	helpers.it("batch_write refuses partial reads and close failures", function()
		for _, terminal in ipairs({ "read", "close" }) do
			local write_opens = 0
			with_file_stubs(function(candidate, mode)
				if mode == "r" then
					return {
						read = function()
							if terminal == "read" then return nil, "I/O error", 5 end
							return "[script]\nenabled = true\n"
						end,
						close = function()
							if terminal == "close" then return false, "flush failed" end
							return true
						end,
					}
				end
				if candidate == "/controlled/config.toml.tmp" then write_opens = write_opens + 1 end
				return nil, "must not stage"
			end, nil, function()
				local ok = writer.batch_write("/controlled/config.toml", {
					{ section = "script", key = "enabled", value = false },
				})
				helpers.assert_eq(ok, false, terminal .. " failure must be terminal")
				helpers.assert_eq(write_opens, 0)
			end)
		end
	end)

	helpers.it("batch_write requires exact staging write and close results", function()
		for _, terminal in ipairs({ "write", "close" }) do
			local renames = 0
			with_file_stubs(function(_, mode)
				if mode == "r" then return nil, "No such file", 2 end
				return {
					write = function(self)
						if terminal == "write" then return nil, "disk full", 28 end
						return self
					end,
					close = function()
						if terminal == "close" then return false, "flush failed" end
						return true
					end,
				}
			end, function()
				renames = renames + 1
				return true
			end, function()
				local ok = writer.batch_write("/controlled/config.toml", {
					{ section = "features", key = "enabled", value = true },
				})
				helpers.assert_eq(ok, false, terminal .. " failure must be terminal")
				helpers.assert_eq(renames, 0)
			end)
		end
	end)

	helpers.it("batch_write refuses a file created after the absence probe", function()
		local source_reads = 0
		local renames = 0
		with_file_stubs(function(_, mode)
			if mode == "r" then
				source_reads = source_reads + 1
				if source_reads == 1 then return nil, "No such file", 2 end
				return {
					read = function() return "[private]\nsentinel = true\n" end,
					close = function() return true end,
				}
			end
			return {
				write = function(self) return self end,
				close = function() return true end,
			}
		end, function()
			renames = renames + 1
			return true
		end, function()
			local ok = writer.batch_write("/controlled/config.toml", {
				{ section = "features", key = "enabled", value = true },
			})
			helpers.assert_eq(ok, false)
			helpers.assert_eq(source_reads, 2, "publication must revalidate the source")
			helpers.assert_eq(renames, 0, "a concurrently created file must survive")
		end)
	end)

	helpers.it("batch_write refuses an existing source changed during staging", function()
		local source_reads = 0
		local renames = 0
		with_file_stubs(function(_, mode)
			if mode == "r" then
				source_reads = source_reads + 1
				local bytes = source_reads == 1
					and "[features]\nenabled = false\n"
					or "[features]\nenabled = true\n# external edit\n"
				return {
					read = function() return bytes end,
					close = function() return true end,
				}
			end
			return {
				write = function(self) return self end,
				close = function() return true end,
			}
		end, function()
			renames = renames + 1
			return true
		end, function()
			local ok = writer.batch_write("/controlled/config.toml", {
				{ section = "features", key = "enabled", value = true },
			})
			helpers.assert_eq(ok, false)
			helpers.assert_eq(renames, 0, "an external edit must not be overwritten")
		end)
	end)

	helpers.it("adapter publication revalidates the exact source snapshot", function()
		local source_reads = 0
		local writes = 0
		local adapter = {
			read_with_status = function()
				source_reads = source_reads + 1
				if source_reads == 1 then return nil, "absent" end
				return "[private]\nsentinel = true\n", "ok"
			end,
			write = function()
				writes = writes + 1
				return true
			end,
		}
		local ok = writer.batch_write("/controlled/config.toml", {
			{ section = "features", key = "enabled", value = true },
		}, adapter)
		helpers.assert_eq(ok, false)
		helpers.assert_eq(source_reads, 2,
			"the adapter-backed writer must revalidate immediately before publication")
		helpers.assert_eq(writes, 0,
			"a file created after the absence proof must never be overwritten")
	end)

	helpers.it("carries the snapshot into the adapter's serialized publication boundary", function()
		local initial = "[features]\nenabled = false\n"
		local ordinary_writes = 0
		local guarded_writes = 0
		local adapter = {
			read_with_status = function()
				-- Both the batch read and the shared last-moment precheck see the
				-- original bytes. The competing writer commits after this return,
				-- while the platform adapter is waiting to acquire its stable lock.
				return initial, "ok"
			end,
			write = function()
				ordinary_writes = ordinary_writes + 1
				return true
			end,
			write_if_unchanged = function(_path, _content, expected_source)
				guarded_writes = guarded_writes + 1
				helpers.assert_eq(expected_source.status, "ok")
				helpers.assert_eq(expected_source.content, initial,
					"the exact batch snapshot must survive into lock-owned publication")
				return false, "source changed while acquiring publication lock"
			end,
		}

		local ok = writer.batch_write("/controlled/config.toml", {
			{ section = "features", key = "enabled", value = true },
		}, adapter)
		helpers.assert_eq(ok, false,
			"a sibling commit between the shared precheck and adapter lock must win, not be overwritten")
		helpers.assert_eq(guarded_writes, 1,
			"classified batch publication must use the adapter's serialized precondition")
		helpers.assert_eq(ordinary_writes, 0,
			"calling the two-argument write port would silently discard the snapshot")
	end)

	helpers.it("batch_write publishes escaped strings that the shared codec can read back", function()
		local captured
		local adapter = {
			read_with_status = function() return nil, "absent" end,
			write = function(_path, content)
				captured = content
				return true
			end,
		}
		local source = "a\nb" .. string.char(1) .. string.char(127)
		local ok = writer.batch_write("/controlled/config.toml", {
			{ section = "script", key = "value", value = source },
		}, adapter)

		helpers.assert_eq(ok, true)
		helpers.assert_contains(captured, 'value = "a\\nb\\u0001\\u007F"')
		local decoded = codec.decode(captured)
		helpers.assert_true(type(decoded) == "table",
			"a successful batch publication must remain valid TOML")
		helpers.assert_eq(decoded.script.value, source,
			"batch_write strings must survive the next parse byte-for-byte")
	end)
end)
