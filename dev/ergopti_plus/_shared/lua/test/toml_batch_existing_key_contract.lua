--- _shared/lua/test/toml_batch_existing_key_contract.lua

--- The batch writer addresses a key whatever spelling already holds it: a
--- table header (the empty headers older macOS builds wrote for every empty
--- map, a structured value such as a shortcut), an array of tables, or a quoted
--- bare-compatible key. It used to refuse each of them with "the batch cannot
--- address an existing quoted or nested key", which failed every macOS menu
--- save, the Hotstrings switch included, on such a config.toml
--- (toml-batch-existing-key).
--- @param helpers table Driver test helpers.
return function(helpers)
	local Writer = require("toml_codec.writer")
	local Codec = require("toml_codec.codec")
	local function prepare(source, rows)
		return Writer.prepare_batch("/controlled/existing-key.toml", rows, {
			read_with_status = function() return source, "ok" end,
			write = function() error("preparation must never publish") end,
		})
	end

	helpers.describe("shared TOML batch over existing key spellings (toml-batch-existing-key)", function()
		helpers.it("deletes a table declared by an empty header and keeps every comment", function()
			local source = '# head\n[llm.models]\nselected = "mlx"\n\n[llm.models.user_models]\n'
				.. '# user-added entries here\n\n\n# ===== 3.4 Profiles =====\n[llm.profiles]\nactive = "basic"\n'
			local ok, detail, content = prepare(source, {
				{ section = "llm.models", key = "user_models", delete = true },
			})
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(content, (source:gsub("%[llm%.models%.user_models%]\n", "", 1)))
		end)

		helpers.it("replaces a header table, its descendants and interleaved blocks by one scalar", function()
			local source = '[metrics]\nenabled = true\n[metrics.shortcut]\nmods = ["cmd"]\nkey = "m"\n'
				.. '[other]\nx = 1\n[metrics.shortcut.extra]\ny = 2\n'
			local ok, detail, content = prepare(source, {
				{ section = "metrics", key = "shortcut", value = false },
			})
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(content, '[metrics]\nshortcut = false\nenabled = true\n[other]\nx = 1\n')
		end)

		helpers.it("removes a header table whose parent has no header of its own", function()
			local source = '[metrics.shortcut]\nmods = ["cmd"]\nkey = "m"\n[neighbor]\nkeep = true\n'
			local ok, detail, content = prepare(source, { { section = "metrics", key = "shortcut", delete = true } })
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(content, '[neighbor]\nkeep = true\n')
			local set_ok, set_detail, set_content = prepare(source, {
				{ section = "metrics", key = "shortcut", value = { key = "k", mods = { "alt" } } },
			})
			helpers.assert_eq(set_ok, true, set_detail)
			local decoded = Codec.decode(set_content)
			helpers.assert_eq(decoded.metrics.shortcut, { key = "k", mods = { "alt" } })
			helpers.assert_eq(decoded.neighbor.keep, true)
		end)

		helpers.it("leaves a value another spelling already holds byte-for-byte", function()
			local list = '[hotstrings]\nexpansion_delay = 0.5\n\n# mine\n[[hotstrings.terminators]]\n'
				.. 'key = "custom_a"\nchar = "a"\nlabel = "a"\nconsume = true\n\n[[hotstrings.terminators]]\n'
				.. 'key = "custom_b"\nchar = "b"\nlabel = "b"\nconsume = false\n'
			local same = {
				{ key = "custom_a", char = "a", label = "a", consume = true },
				{ key = "custom_b", char = "b", label = "b", consume = false },
			}
			for _, case in ipairs({
				{ list, { section = "hotstrings", key = "terminators", value = same } },
				{ '[hotstrings.delays]\n# none yet\n', { section = "hotstrings", key = "delays", value = {} } },
				{ 'hotstrings = { enabled = false }\n', { section = "hotstrings", key = "enabled", value = false } },
			}) do
				local ok, detail, content = prepare(case[1], { case[2] })
				helpers.assert_eq(ok, true, detail)
				helpers.assert_eq(content, case[1])
			end
		end)

		helpers.it("rewrites a changed array of tables as one inline list and keeps its comments", function()
			local source = '[hotstrings]\nexpansion_delay = 0.5\n\n# mine\n[[hotstrings.terminators]]\n'
				.. 'key = "custom_a"\nchar = "a"\nlabel = "a"\nconsume = true\n[next]\nv = 1\n'
			local list = {
				{ key = "custom_a", char = "a", label = "a", consume = false },
				{ key = "custom_c", char = "c", label = "c", consume = true },
			}
			local ok, detail, content = prepare(source, { { section = "hotstrings", key = "terminators", value = list } })
			helpers.assert_eq(ok, true, detail)
			local decoded = Codec.decode(content)
			helpers.assert_eq(decoded.hotstrings.terminators, list)
			helpers.assert_eq(decoded.hotstrings.expansion_delay, 0.5)
			helpers.assert_eq(decoded.next.v, 1)
			helpers.assert_true(content:find("# mine\n", 1, true) ~= nil, "a comment is never dropped")
			helpers.assert_true(content:find("[[", 1, true) == nil, "no array-of-tables header is left")
		end)

		helpers.it("updates and deletes a quoted bare-compatible key in place", function()
			for _, spelling in ipairs({ '"enabled"', "'enabled'" }) do
				local source = '[shortcuts]\n' .. spelling .. ' = true\nother = 1\n'
				local ok, detail, content = prepare(source, { { section = "shortcuts", key = "enabled", value = false } })
				helpers.assert_eq(ok, true, detail)
				helpers.assert_eq(content, '[shortcuts]\nenabled = false\nother = 1\n')
				local deleted, delete_detail, remaining = prepare(source, { { section = "shortcuts", key = "enabled", delete = true } })
				helpers.assert_eq(deleted, true, delete_detail)
				helpers.assert_eq(remaining, '[shortcuts]\nother = 1\n')
			end
			local ok, detail, content = prepare('[hotstrings.groups]\n"autocorrection" = false\n', {
				{ section = "hotstrings.groups", key = "autocorrection", value = true },
			})
			helpers.assert_eq(ok, true, detail)
			helpers.assert_eq(content, '[hotstrings.groups]\nautocorrection = true\n')
		end)

		helpers.it("names the key an inline table holds when its value changes", function()
			for _, source in ipairs({ 'hotstrings = { enabled = false }\n', '[metrics]\nshortcut = { key = "m" }\n' }) do
				local section = source:find("hotstrings", 1, true) and "hotstrings" or "metrics.shortcut"
				local key = section == "hotstrings" and "enabled" or "key"
				local ok, detail = prepare(source, { { section = section, key = key, value = "changed" } })
				helpers.assert_eq(ok, false, source)
				helpers.assert_true(tostring(detail):find(section .. "." .. key, 1, true) ~= nil, tostring(detail))
				helpers.assert_true(tostring(detail):find("inline", 1, true) ~= nil, tostring(detail))
			end
		end)

		helpers.it("refuses a batch that replaces a header table and writes inside it", function()
			local source = '[metrics.shortcut]\nmods = ["cmd"]\nkey = "m"\n'
			local ok, detail = prepare(source, {
				{ section = "metrics", key = "shortcut", delete = true },
				{ section = "metrics.shortcut", key = "key", value = "x" },
			})
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(detail):find("metrics.shortcut", 1, true) ~= nil, tostring(detail))
		end)
	end)
end
