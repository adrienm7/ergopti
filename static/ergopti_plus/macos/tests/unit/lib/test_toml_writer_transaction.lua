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
	helpers.it("uses a conditional-only adapter without escaping to native filesystem publication", function()
		local source, writes = '[shortcuts]\nenabled = true\n', 0
		with_file_stubs(function() error("an explicit adapter owns every file operation") end, nil, function()
			local wrote = writer.batch_write("/controlled/conditional-only.toml", {
				{ section = "shortcuts", key = "enabled", delete = true },
			}, {
				read_with_status = function() return source, "ok" end,
				write_if_unchanged = function(_, candidate, expected)
					helpers.assert_eq(expected.content, source)
					source, writes = candidate, writes + 1
					return true
				end,
			})
			helpers.assert_eq(wrote, true)
		end)
		helpers.assert_eq(writes, 1)
		helpers.assert_eq(source:find("enabled", 1, true), nil)
	end)

	helpers.it("batch_write commits sparse deletes and sets without moving unrelated keys", function()
		local initial = '# Keep this comment.\n[shortcuts]\nenabled = true\nfuture = "keep"\n'
			.. '[expert]\nvalue = "unchanged"\n'
		local captured, writes = nil, 0
		local wrote = writer.batch_write("/controlled/sparse.toml", {
			{ section = "shortcuts", key = "enabled", delete = true },
			{ section = "shortcuts", key = "custom", value = "chosen" },
			{ section = "absent", key = "enabled", delete = true },
		}, {
			read_with_status = function() return initial, "ok" end,
			write = function() error("sparse writes require exact source publication") end,
			write_if_unchanged = function(_, content, expected)
				writes = writes + 1
				helpers.assert_eq(expected.content, initial)
				captured = content
				return true
			end,
		})
		helpers.assert_eq(wrote, true, "explicit deletion is a valid batch operation")
		helpers.assert_eq(writes, 1, "mixed changes must publish together")
		local decoded = codec.decode(captured)
		helpers.assert_eq(decoded.shortcuts.enabled, nil)
		helpers.assert_eq(decoded.shortcuts.custom, "chosen")
		helpers.assert_eq(decoded.shortcuts.future, "keep")
		helpers.assert_eq(decoded.expert.value, "unchanged")
		helpers.assert_eq(decoded.expert.custom, nil)
		helpers.assert_eq(decoded.absent, nil, "deleting an absent leaf must not create a section")
		helpers.assert_contains(captured, '# Keep this comment.\n')
	end)

	helpers.it("batch_write keeps multiline lookalikes intact when deleting a real leaf", function()
		local initial = '[expert]\nnote = """\n[shortcuts]\nenabled = true\n"""\n'
			.. '[shortcuts] # real section\nenabled = true\nfuture = [\n  "keep",\n]\n'
		local captured
		helpers.assert_eq(writer.batch_write("/controlled/multiline-sparse.toml", {
			{ section = "shortcuts", key = "enabled", delete = true },
		}, {
			read_with_status = function() return initial, "ok" end,
			write = function() error("sparse writes require exact source publication") end,
			write_if_unchanged = function(_, content) captured = content; return true end,
		}), true)
		local decoded = codec.decode(captured)
		helpers.assert_eq(decoded.shortcuts.enabled, nil)
		helpers.assert_eq(decoded.shortcuts.future[1], "keep")
		helpers.assert_eq(decoded.expert.note, '[shortcuts]\nenabled = true\n')
		helpers.assert_contains(captured, '[expert]\nnote = """\n[shortcuts]\nenabled = true\n"""\n')
	end)

	helpers.it("batch_write refuses a mixed sparse transaction without changing its source", function()
		local disk = '[shortcuts]\nenabled = true\n[expert]\nkeep = 7\n'
		local original, publications = disk, 0
		local wrote = writer.batch_write("/controlled/refused-sparse.toml", {
			{ section = "shortcuts", key = "enabled", delete = true },
			{ section = "shortcuts", key = "custom", value = "chosen" },
		}, {
			read_with_status = function() return disk, "ok" end,
			write = function() error("sparse writes require exact source publication") end,
			write_if_unchanged = function(_, content, expected)
				publications = publications + 1
				helpers.assert_eq(expected.content, original)
				helpers.assert_eq(codec.decode(content).shortcuts.custom, "chosen")
				return false, "injected publication refusal"
			end,
		})
		helpers.assert_eq(wrote, false)
		helpers.assert_eq(publications, 1, "the refusal must exercise publication, not validation")
		helpers.assert_eq(disk, original)
	end)

	helpers.it("batch_write rejects a snapshot superseded before the save begins", function()
		local writes = 0
		local wrote = writer.batch_write("/controlled/stale-sparse.toml", {
			{ section = "shortcuts", key = "enabled", value = true },
		}, {
			read_with_status = function() return '[shortcuts]\nenabled = false\n', "ok" end,
			write = function() writes = writes + 1; return true end,
		}, { status = "ok", content = '[shortcuts]\nenabled = true\n' })
		helpers.assert_eq(wrote, false)
		helpers.assert_eq(writes, 0, "an old runtime snapshot cannot overwrite a newer disk edit")
	end)

	helpers.it("batch_write rejects malformed documents and ambiguous quoted targets", function()
		-- A lone quoted key is one key (toml-batch-existing-key); two spellings
		-- the batch folds to one identity are still ambiguous.
		for _, source in ipairs({ '[shortcuts]\nenabled = true\nenabled = false\n',
			'[shortcuts]\n"enabled" = true\nEnabled = false\n' }) do
			local writes = 0
			local wrote = writer.batch_write("/controlled/invalid-sparse.toml", {
				{ section = "shortcuts", key = "enabled", value = false },
			}, {
				read_with_status = function() return source, "ok" end,
				write = function() writes = writes + 1; return true end,
			})
			helpers.assert_eq(wrote, false)
			helpers.assert_eq(writes, 0)
		end
	end)

	helpers.it("batch_write never reports an unaddressable deletion as committed", function()
		local writes = 0
		local wrote = writer.batch_write("/controlled/inline-delete.toml", {
			{ section = "shortcuts", key = "enabled", delete = true },
		}, {
			read_with_status = function() return 'shortcuts = { enabled = true }\n', "ok" end,
			write = function() writes = writes + 1; return true end,
		})
		helpers.assert_eq(wrote, false)
		helpers.assert_eq(writes, 0)
		-- A quoted spelling of the same key is addressable, and its deletion
		-- commits only with the key gone (toml-batch-existing-key).
		local published = nil
		local deleted = writer.batch_write("/controlled/quoted-delete.toml", {
			{ section = "shortcuts", key = "enabled", delete = true },
		}, {
			read_with_status = function() return '[shortcuts]\n"enabled" = true\n', "ok" end,
			write = function(_, content) published = content; return true end,
		})
		helpers.assert_eq(deleted, true)
		helpers.assert_eq(published, '[shortcuts]\n')
	end)

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
			{ section = "script", key = "value", value = function() end },
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

	helpers.it("batch_write appends new sections in deterministic order", function()
		local updates = {
			{ section = "hotstrings", key = "enabled", value = true },
			{ section = "hotstrings", key = "expansion_delay", value = 15 },
			{ section = "metrics", key = "enabled", value = false },
			{ section = "gestures", key = "enabled", value = true },
		}
		local function capture_with_pending_order(section_order)
			local captured
			local original_pairs = pairs
			pairs = function(subject)
				if type(subject) == "table"
					and subject.gestures and subject.hotstrings and subject.metrics then
					local index = 0
					return function()
						index = index + 1
						local section = section_order[index]
						if section then return section, subject[section] end
					end
				end
				return original_pairs(subject)
			end
			local call_ok, call_err = xpcall(function()
				local wrote = writer.batch_write("/controlled/config.toml", updates, {
					read_with_status = function() return nil, "absent" end,
					write = function(_path, content)
						captured = content
						return true
					end,
				})
				helpers.assert_eq(wrote, true)
			end, debug.traceback)
			pairs = original_pairs
			if not call_ok then error(call_err, 0) end
			return captured
		end

		local ascending = capture_with_pending_order({ "gestures", "hotstrings", "metrics" })
		local descending = capture_with_pending_order({ "metrics", "hotstrings", "gestures" })
		helpers.assert_eq(descending, ascending,
			"equivalent fresh writes must not depend on Lua hash iteration order")
		local gestures_at = assert(ascending:find("[gestures]", 1, true))
		local hotstrings_at = assert(ascending:find("[hotstrings]", 1, true))
		local metrics_at = assert(ascending:find("[metrics]", 1, true))
		helpers.assert_true(gestures_at < hotstrings_at and hotstrings_at < metrics_at,
			"new section headers must use the codec's lexical order")
		local enabled_at = assert(ascending:find("enabled = true", hotstrings_at, true))
		local delay_at = assert(ascending:find("expansion_delay = 15", hotstrings_at, true))
		helpers.assert_true(enabled_at < delay_at,
			"updates inside one section must retain caller order")
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

	helpers.it("publishes arrays and inline tables together with an explicit deletion", function()
		local captured
		local adapter = {
			read_with_status = function() return "[llm]\nenabled = true\n", "ok" end,
			write = function(_, content) captured = content; return true end,
		}
		local ok = writer.batch_write("/controlled/compound.toml", {
			{ section = "llm", key = "enabled", delete = true },
			{ section = "llm", key = "modifiers", value = { "ctrl", "shift" } },
			{ section = "llm", key = "profile", value = { name = "draft", temperature = 0.7 } },
		}, adapter)
		helpers.assert_eq(ok, true)
		local decoded = codec.decode(captured)
		helpers.assert_eq(decoded.llm.enabled, nil)
		helpers.assert_eq(decoded.llm.modifiers[2], "shift")
		helpers.assert_eq(decoded.llm.profile.temperature, 0.7)
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

require("test.toml_quoted_headers_contract")(helpers)
require("test.toml_batch_existing_key_contract")(helpers)
require("test.toml_leaf_rows_contract")(helpers)

local noop_vectors_file = assert(io.open(helpers.shared("tests/corpus/config_noop/vectors.json"), "rb"))
local noop_vectors = assert(require("json").decode(noop_vectors_file:read("*a")))
noop_vectors_file:close()
require("test.toml_noop_contract")(helpers, noop_vectors)

require("test.toml_dotted_keys_contract")(helpers)

local source_vectors_file = assert(io.open(helpers.shared("tests/corpus/config_source_preservation/vectors.json"), "rb"))
local source_vectors = assert(require("json").decode(source_vectors_file:read("*a")))
source_vectors_file:close()
require("test.toml_source_preservation_contract")(helpers, source_vectors)
