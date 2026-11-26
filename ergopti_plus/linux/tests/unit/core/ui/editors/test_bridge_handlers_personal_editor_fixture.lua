--- tests/unit/core/ui/editors/test_bridge_handlers_personal_editor_fixture.lua

--- ==============================================================================
--- Tier 2 — Integration tests for UI bridge handlers + webview manager.
--- Tests all 14 bridge handlers and the webview_manager routing layer.
--- Pure Lua — no GTK/WebKit2GTK required.
--- ==============================================================================

package.loaded["tests.support.ui.editors.ui_bridge_handlers_fixture"] = nil
local Fixture = require("tests.support.ui.editors.ui_bridge_handlers_fixture")
local helpers, OPENING_SOURCE, OPENING_FOREIGN, opening_model, with_opening_file =
	Fixture.helpers, Fixture.OPENING_SOURCE, Fixture.OPENING_FOREIGN, Fixture.opening_model, Fixture.with_opening_file




helpers.describe("personal editor literal brace payload", function()
	helpers.it("persists literal symbols and non-BMP text through the real bridge", function()
		with_opening_file(function(f)
			helpers.assert_true(f.ready())
			local output = "x {a&b} {x<😀} {foo}"
			helpers.assert_true(f.save(output).saved)
			local decoded = assert(require("core.text.engine.toml_codec").decode(f.read()))
			helpers.assert_eq(decoded.english.old.output, output)
		end)
	end)
end)

-- EDD-1 (maintainer, 2026-11-12): a pause stops typing, not configuration.
helpers.describe("personal hotstrings editor while paused", function()
	helpers.it("saves the page's hotstrings while the daemon is paused (edd1-paused-writes)", function()
		with_opening_file(function(f)
			f.state.is_paused = function() return true end
			helpers.assert_true(f.ready())
			helpers.assert_true(f.save("written while paused").saved)
			local decoded = assert(require("core.text.engine.toml_codec").decode(f.read()))
			helpers.assert_eq(decoded.english.old.output, "written while paused")
		end)
	end)
end)

helpers.describe("personal editor row origins", function()
	helpers.it("preserves source metadata and comment across move, rename and later save", function()
		with_opening_file(function(f)
			f.put('[_meta]\nsections_order = ["english", "second"]\n[english]\n"café" = { output = "résumé", future = "keep", priority = 73, is_case_sensitive = true, is_case_sensitive_strict = true } # retained\n[second]\n')
			helpers.assert_true(f.ready())
			local script = f.seen.deliveries[1]
			local opening = require("core.text.engine.json").decode(assert(script:match("window.initData%((.*)%)")))
			local row = opening.sections[1].entries[1]
			row.trigger, row.output = "été", "changed"
			local data = { sections_order = { "english", "second" }, sections = {
				english = { description = "english", entries = {} },
				second = { description = "second", entries = { row } },
			} }
			helpers.assert_true(f.handler.on_message({ action = "save", data = data }, f.state, f.context).saved)
			local parsed = assert(require("core.text.engine.toml_codec").decode(f.read()))
			helpers.assert_eq(parsed.second["été"].future, "keep")
			helpers.assert_eq(parsed.second["été"].output, "changed")
			helpers.assert_eq(parsed.second["été"].priority, 73)
			helpers.assert_eq(parsed.second["été"].is_case_sensitive_strict, true)
			helpers.assert_eq(select(2, f.read():gsub("# retained", "")), 1)
			row.trigger, row.output = "été2", "again"
			helpers.assert_true(f.handler.on_message({ action = "save", data = data }, f.state, f.context).saved)
			parsed = assert(require("core.text.engine.toml_codec").decode(f.read()))
			helpers.assert_eq(parsed.second["été2"].future, "keep")
			helpers.assert_eq(parsed.second["été2"].output, "again")
			data.sections_order = { "english", "second", "third" }
			data.sections.second.entries = {}
			data.sections.third = { description = "third", entries = { row } }
			helpers.assert_true(f.handler.on_message({ action = "save", data = data }, f.state, f.context).saved)
			parsed = assert(require("core.text.engine.toml_codec").decode(f.read()))
			local third = parsed.third[1] or parsed.third
			helpers.assert_eq(third["été2"].future, "keep")
			helpers.assert_eq(select(2, f.read():gsub("# retained", "")), 1)
		end)
	end)
	helpers.it("does not attach a removed row's metadata to a new row with the same trigger", function()
		with_opening_file(function(f)
			f.put('[_meta]\nsections_order = ["english"]\n[english]\n"old" = { output = "a", future = "secret" } # comment\n')
			helpers.assert_true(f.ready())
			local row = { origin_id = "new:1", trigger = "old", output = "new", is_word = false, auto_expand = false,
				is_case_sensitive = false, final_result = false, is_case_sensitive_strict = false }
			local data = { sections_order = { "english" }, sections = { english = { description = "english", entries = { row } } } }
			helpers.assert_true(f.handler.on_message({ action = "save", data = data }, f.state, f.context).saved)
			local parsed = assert(require("core.text.engine.toml_codec").decode(f.read()))
			helpers.assert_nil(parsed.english.old.future)
			helpers.assert_eq(parsed.english.old.output, "new")
		end)
	end)
	helpers.it("refuses duplicated or unrecognized snapshot identities", function()
		with_opening_file(function(f)
			helpers.assert_true(f.ready())
			local opening = require("core.text.engine.json").decode(assert(f.seen.deliveries[1]:match("window.initData%((.*)%)")))
			local row = opening.sections[1].entries[1]
			local second = {}; for key, value in pairs(row) do second[key] = value end
			second.trigger = "different"
			local data = { sections_order = { "english" }, sections = { english = { description = "english", entries = { row, second } } } }
			helpers.assert_eq(f.handler.on_message({ action = "save", data = data }, f.state, f.context).saved, false)
			helpers.assert_eq(f.read(), OPENING_SOURCE)
			row.origin_id = "row:999"; data.sections.english.entries = { row }
			helpers.assert_eq(f.handler.on_message({ action = "save", data = data }, f.state, f.context).saved, false)
			helpers.assert_eq(f.read(), OPENING_SOURCE)
		end)
	end)

	helpers.it("retains the opening origin after a refused save", function()
		with_opening_file(function(f)
			f.put('[_meta]\nsections_order = ["english"]\n[english]\n"old" = { output = "a", future = "retained" }\n')
			helpers.assert_true(f.ready())
			local opening = require("core.text.engine.json").decode(assert(f.seen.deliveries[1]:match("window.initData%((.*)%)")))
			local row = opening.sections[1].entries[1]; row.trigger = "renamed"
			local data = { sections_order = { "english" }, sections = { english = { description = "english", entries = { row } } } }
			local write = f.publisher.write; f.publisher.write = function() return false, "refused" end
			helpers.assert_eq(f.handler.on_message({ action = "save", data = data }, f.state, f.context).saved, false)
			f.publisher.write = write
			helpers.assert_true(f.handler.on_message({ action = "save", data = data }, f.state, f.context).saved)
			local parsed = assert(require("core.text.engine.toml_codec").decode(f.read()))
			helpers.assert_eq(parsed.english.renamed.future, "retained")
		end)
	end)

	helpers.it("keeps identities distinct for matching triggers in different sections", function()
		with_opening_file(function(f)
			f.put('[_meta]\nsections_order = ["english", "second"]\n[english]\n"same" = { output = "one", future = "first" }\n[second]\n"same" = { output = "two", future = "second" }\n')
			helpers.assert_true(f.ready())
			local opening = require("core.text.engine.json").decode(assert(f.seen.deliveries[1]:match("window.initData%((.*)%)")))
			local first, second = opening.sections[1].entries[1], opening.sections[2].entries[1]
			local data = { sections_order = { "english", "second" }, sections = {
				english = { description = "english", entries = { second } },
				second = { description = "second", entries = { first } },
			} }
			helpers.assert_true(f.handler.on_message({ action = "save", data = data }, f.state, f.context).saved)
			local parsed = assert(require("core.text.engine.toml_codec").decode(f.read()))
			helpers.assert_eq(parsed.english.same.future, "second")
			helpers.assert_eq(parsed.second.same.future, "first")
		end)
	end)

end)

helpers.describe("personal editor fixture process ABI", function()
	local function with_real_shell(body)
		local prior = package.loaded["core.process.adapters.shell_runner"]
		package.loaded["core.process.adapters.shell_runner"] = nil
		local Shell = require("core.process.adapters.shell_runner")
		local native_execute = os.execute
		local called, failure = pcall(body, Shell, native_execute)
		os.execute = native_execute
		package.loaded["core.process.adapters.shell_runner"] = prior
		if not called then error(failure, 0) end
	end
	helpers.it("requires physical mkdir, exact data readback and cleanup through the existing status owner", function()
		with_real_shell(function(Shell, native_execute)
			local directory = os.tmpname(); assert(os.remove(directory))
			directory = directory .. "-ergopti-personal-abi"
			local quote, path = Shell.quote, directory .. "/independent.txt"
			local calls = 0
			os.execute = function(command)
				calls = calls + 1
				return native_execute(command)
			end
			local made = Shell.run("mkdir -p " .. quote(directory))
			local called, readback = pcall(function()
				local file = assert(io.open(path, "wb")); assert(file:write("independent physical bytes\n")); assert(file:close())
				file = assert(io.open(path, "rb")); local data = assert(file:read("*a")); assert(file:close())
				return data
			end)
			local refused = Shell.run("exit 1")
			local removed = Shell.run("rm -rf " .. quote(directory))
			os.execute = native_execute
			helpers.assert_eq(made, true)
			helpers.assert_eq({ called, readback }, { true, "independent physical bytes\n" })
			helpers.assert_eq(refused, false, "an actual nonzero child cannot become an acknowledgement")
			helpers.assert_eq(removed, true)
			helpers.assert_eq(calls, 3, "all three owned command boundaries reached the real os.execute port")
			local file = io.open(path, "rb"); if file then file:close() end
			helpers.assert_eq(file, nil, "the physical private source was retired")
		end)
	end)
	for _, outcome in ipairs({ "false", "nil", "number", "text", "throw" }) do
		helpers.it("refuses a non-success process receipt " .. outcome, function()
			with_real_shell(function(Shell, native_execute)
				local calls = 0
				os.execute = function()
					calls = calls + 1
					if outcome == "throw" then error("inert native process refusal") end
					if outcome == "nil" then return nil, "exit", 1 end
					if outcome == "number" then return 2 end
					if outcome == "text" then return "true" end
					return false, "exit", 1
				end
				local acknowledged = Shell.run("/nonexistent/inert-non-executed-fixture-command")
				os.execute = native_execute
				helpers.assert_eq(acknowledged, false)
				helpers.assert_eq(calls, 1, "a retained test runner must not bypass the real status boundary")
			end)
		end)
	end
end)




helpers.describe("personal editor opening-source admission", function()
	for _, mode in ipairs({ "missing_order", "missing_section", "unlisted_section", "duplicate_order" }) do
		helpers.it("(personal-save-model) refuses incomplete section model: " .. mode, function()
			with_opening_file(function(f)
				helpers.assert_true(f.ready())
				local data = opening_model("edited")
				if mode == "missing_order" then data.sections_order = nil
				elseif mode == "missing_section" then data.sections[data.sections_order[1]] = nil
				elseif mode == "unlisted_section" then data.sections.foreign = { entries = {} }
				else data.sections_order[#data.sections_order + 1] = data.sections_order[1] end
				local result = f.handler.on_message({ action = "save", data = data }, f.state, f.context)
				helpers.assert_eq(result.saved, false)
				helpers.assert_eq(f.read(), OPENING_SOURCE)
				helpers.assert_eq(f.seen.writes, 0)
			end)
		end)
	end

	for _, mode in ipairs({ "missing_entries", "invalid_entries", "missing_output", "invalid_output" }) do
		helpers.it("(personal-save-entries) refuses incomplete entry model: " .. mode, function()
			with_opening_file(function(f)
				helpers.assert_true(f.ready())
				local data = opening_model("edited")
				local section = data.sections.english
				if mode == "missing_entries" then section.entries = nil
				elseif mode == "invalid_entries" then section.entries = "invalid"
				elseif mode == "missing_output" then section.entries[1].output = nil
				else section.entries[1].output = {} end
				local result = f.handler.on_message({ action = "save", data = data }, f.state, f.context)
				helpers.assert_eq(result.saved, false)
				helpers.assert_eq(f.read(), OPENING_SOURCE)
				helpers.assert_eq(f.seen.writes, 0)
			end)
		end)
	end

	for _, mode in ipairs({ "invalid_flag", "invalid_priority", "infinite_priority" }) do
		helpers.it("(personal-save-flags) refuses invalid row field: " .. mode, function()
			with_opening_file(function(f)
				helpers.assert_true(f.ready())
				local data = opening_model("edited")
				local entry = data.sections.english.entries[1]
				if mode == "invalid_flag" then entry.is_word = "true"
				elseif mode == "invalid_priority" then entry.priority = "42"
				else entry.priority = math.huge end
				local result = f.handler.on_message({ action = "save", data = data }, f.state, f.context)
				helpers.assert_eq(result.saved, false)
				helpers.assert_eq(f.read(), OPENING_SOURCE)
				helpers.assert_eq(f.seen.writes, 0)
			end)
		end)
	end

	for _, mode in ipairs({ "missing", "empty", "invalid" }) do
		helpers.it("(personal-save-trigger) refuses a " .. mode .. " trigger without erasing its row", function()
			with_opening_file(function(f)
				helpers.assert_true(f.ready())
				local data = opening_model("edited")
				local entry = data.sections.english.entries[1]
				if mode == "missing" then entry.trigger = nil
				elseif mode == "empty" then entry.trigger = ""
				else entry.trigger = 12 end
				local result = f.handler.on_message({ action = "save", data = data }, f.state, f.context)
				helpers.assert_eq(result.saved, false)
				helpers.assert_eq(f.read(), OPENING_SOURCE)
				helpers.assert_eq(f.seen.writes, 0)
			end)
		end)
	end

	for _, mode in ipairs({ "missing", "invalid" }) do
		helpers.it("(personal-save-description) refuses " .. mode .. " section description", function()
			with_opening_file(function(f)
				local original = '[_meta]\nsections_order = ["english"]\n[_meta.sections]\nenglish = "Existing description"\n[english]\n"old" = { output = "original" }\n'
				f.put(original)
				helpers.assert_true(f.ready())
				local data = opening_model("edited")
				if mode == "missing" then data.sections.english.description = nil
				else data.sections.english.description = {} end
				local result = f.handler.on_message({ action = "save", data = data }, f.state, f.context)
				helpers.assert_eq(result.saved, false)
				helpers.assert_eq(f.read(), original)
				helpers.assert_eq(f.seen.writes, 0)
			end)
		end)
	end
	helpers.it("(personal-save-serialization) rejects a reentrant save while the committed model reloads", function()
		with_opening_file(function(f)
			helpers.assert_true(f.ready())
			local nested, stale
			f.state.config.reload = function()
				f.seen.reloads = f.seen.reloads + 1
				if not nested then
					nested = {}
					stale = f.save("stale edit", {})
					nested = f.save("second edit")
				end
				return 0, true
			end
			local first = f.save("first edit")
			helpers.assert_eq(first.saved, true)
			helpers.assert_eq(stale, { saved = false, busy = true })
			helpers.assert_eq(nested, { saved = false, busy = true })
			helpers.assert_contains(f.read(), "first edit")
			helpers.assert_true(not f.read():find("second edit", 1, true))
			helpers.assert_eq(f.seen.writes, 1)
			helpers.assert_eq(f.seen.reloads, 1)
		end)
	end)

	helpers.it("(personal-save-flags) refuses a missing displayed flag without clearing it", function()
		with_opening_file(function(f)
			helpers.assert_true(f.ready())
			local data = opening_model("edited")
			data.sections.english.entries[1].is_word = nil
			local result = f.handler.on_message({ action = "save", data = data }, f.state, f.context)
			helpers.assert_eq(result.saved, false)
			helpers.assert_eq(f.read(), OPENING_SOURCE)
			helpers.assert_eq(f.seen.writes, 0)
		end)
	end)

	helpers.it("refuses a foreign section added after the actual displayed model", function()
		with_opening_file(function(f)
			helpers.assert_eq(f.ready(), true)
			helpers.assert_true(f.seen.deliveries[1]:find('"original"', 1, true) ~= nil)
			f.put(OPENING_FOREIGN)
			local result = f.save("stale replacement")
			helpers.assert_eq(result.saved, false)
			helpers.assert_eq(f.read(), OPENING_FOREIGN)
			helpers.assert_eq(f.seen.writes, 0)
			helpers.assert_eq(f.seen.reloads, 0)
			helpers.assert_eq(#f.seen.alerts, 1)
		end)
	end)

	helpers.it("advances only our committed payload for a second actual save", function()
		with_opening_file(function(f)
			helpers.assert_eq(f.ready(), true)
			local first = f.save("first own edit")
			helpers.assert_eq(first.saved, true)
			helpers.assert_true(f.read():find('first own edit', 1, true) ~= nil)
			local second = f.save("second own edit")
			helpers.assert_eq(second.saved, true)
			helpers.assert_true(f.read():find('second own edit', 1, true) ~= nil)
			helpers.assert_eq(f.seen.reloads, 2)
		end)
	end)

	helpers.it("fresh reopening admits the new source while the old held view refuses", function()
		with_opening_file(function(f)
			helpers.assert_eq(f.ready(), true); f.put(OPENING_FOREIGN)
			helpers.assert_eq(f.save("old").saved, false)
			helpers.assert_eq(f.ready(), true)
			helpers.assert_true(f.seen.deliveries[2]:find('"future"', 1, true) ~= nil)
			helpers.assert_eq(f.save("explicit new view edit").saved, true)
		end)
	end)

	for _, change in ipairs({ "epoch", "route", "context", "missing" }) do
		helpers.it("refuses a retired opening owner: " .. change, function()
			with_opening_file(function(f)
				helpers.assert_eq(f.ready(), true)
				local selected = f.context
				if change == "epoch" then f.seen.epoch = 52
				elseif change == "route" then f.state.config.get_config_dir = function() return f.path .. "-foreign-route" end
				elseif change == "context" then selected = { app_name = "another_app", epoch = 51 }
				else selected = {} end
				local result = f.save("retired", selected)
				helpers.assert_eq(result.saved, false)
				helpers.assert_eq(f.read(), OPENING_SOURCE)
				helpers.assert_eq(f.seen.writes, 0)
			end)
		end)
	end

	for _, refusal in ipairs({ "false", "nil", "number", "throw" }) do
		helpers.it("failed initData cannot lend editable authority: " .. refusal, function()
			with_opening_file(function(f)
				f.seen.delivery = refusal
				local opened = f.ready()
				local result = f.save("never displayed")
				helpers.assert_eq(opened, false)
				helpers.assert_eq(result.saved, false)
				helpers.assert_eq(f.read(), OPENING_SOURCE)
				helpers.assert_eq(f.seen.writes, 0)
			end)
		end)
	end

	for _, source in ipairs({ "malformed", "read_refusal", "absent" }) do
		helpers.it("classifies the opening source before displaying it: " .. source, function()
			with_opening_file(function(f)
				if source == "malformed" then f.put('[english\nbroken = 2\n')
				elseif source == "read_refusal" then f.publisher.read_classified = function() return nil, "error" end
				else assert(os.remove(f.path)) end
				local opened = f.ready()
				local result = f.save("admitted absence")
				if source == "absent" then
					helpers.assert_eq(opened, true); helpers.assert_eq(result.saved, true)
					helpers.assert_true(f.read():find('admitted absence', 1, true) ~= nil)
				else
					helpers.assert_eq(opened, false); helpers.assert_eq(result.saved, false)
					helpers.assert_eq(f.seen.writes, 0)
				end
			end)
		end)
	end

	for _, result in ipairs({ "false", "nil", "number", "text", "throw" }) do
		helpers.it("refused publication preserves opening authority and supports owned retry: " .. result, function()
			with_opening_file(function(f)
				helpers.assert_eq(f.ready(), true)
				local real = f.publisher.write
				f.publisher.write = function()
					if result == "throw" then error("inert write refusal") end
					if result == "number" then return 1, nil, OPENING_SOURCE end
					if result == "text" then return "accepted", nil, OPENING_SOURCE end
					if result == "false" then return false end
					return nil
				end
				local refused = f.save("not published")
				helpers.assert_eq(refused.saved, false)
				helpers.assert_eq(f.read(), OPENING_SOURCE)
				helpers.assert_eq(f.seen.reloads, 0)
				f.publisher.write = real
				helpers.assert_eq(f.save("owned retry").saved, true)
			end)
		end)
	end

	helpers.it("passes the retained source into the actual stage-time CAS owner", function()
		with_opening_file(function(f)
			helpers.assert_eq(f.ready(), true)
			local captured
			f.publisher.write = function(path, data, adapter, create, source)
				captured = source.content
				f.put(OPENING_FOREIGN)
				return f.writer.write(path, data, adapter, create, source)
			end
			local result = f.save("stage replacement")
			helpers.assert_eq(captured, OPENING_SOURCE)
			helpers.assert_eq(result.saved, false)
			helpers.assert_eq(f.read(), OPENING_FOREIGN)
			helpers.assert_eq(f.seen.reloads, 0)
		end)
	end)

	helpers.it("post-ACK foreign bytes cannot become our next-save authority", function()
		with_opening_file(function(f)
			helpers.assert_eq(f.ready(), true)
			f.publisher.write = function(...)
				local ok, detail, payload = f.writer.write(...)
				f.put(OPENING_FOREIGN)
				return ok, detail, payload
			end
			local first = f.save("our committed edit")
			helpers.assert_eq(first.saved, true, "existing publication ACK is separate from later external replacement")
			local second = f.save("must not borrow foreign source")
			helpers.assert_eq(second.saved, false)
			helpers.assert_eq(f.read(), OPENING_FOREIGN)
		end)
	end)

	helpers.it("keeps the existing saved-but-reload-refused policy", function()
		with_opening_file(function(f)
			helpers.assert_eq(f.ready(), true); f.seen.reload_throw = true
			local saved = f.save("durable despite reload refusal")
			helpers.assert_eq(saved.saved, true)
			helpers.assert_true(f.read():find('durable despite reload refusal', 1, true) ~= nil)
			f.seen.reload_throw = false
			helpers.assert_eq(f.save("later owned save").saved, true)
		end)
	end)
end)




helpers.describe("personal editor opening-source admission", function()
	helpers.it("uses the actual manager route and rejects retired page epochs", function()
		with_opening_file(function(f)
			local port = package.loaded["core.ui.ui.webview_manager"]
			package.loaded["core.ui.ui.webview_manager"] = nil
			local Manager = require("core.ui.ui.webview_manager")
			local html, creator, evaluate = Manager.build_page_html, Manager._create_gtk_window, Manager.eval_js
			Manager.build_page_html = function() return "<html>inert recorded page</html>" end
			Manager._create_gtk_window = function() return true end
			Manager.eval_js = port.eval_js
			Manager.set_daemon_state(f.state)
			local ok, err = pcall(function()
				helpers.assert_eq(Manager.show("hotstring_editor", "en"), true)
				local first = Manager.current_epoch("hotstring_editor")
				Manager.route_message("hotstring_editor", "hsEditor", "ready", first)
				local saved = Manager.route_message("hotstring_editor", "hsEditor", {
					action = "save", data = opening_model("actual managed route") }, first)
				helpers.assert_eq(saved.saved, true)
				helpers.assert_eq(Manager.hide("hotstring_editor", first), true)
				helpers.assert_eq(Manager.show("hotstring_editor", "en"), true)
				local second = Manager.current_epoch("hotstring_editor")
				helpers.assert_true(second > first)
				local bytes = f.read()
				local routed = Manager.route_message("hotstring_editor", "hsEditor", {
					action = "save", data = opening_model("stale route") }, first)
				local direct = f.save("stale direct owner", { app_name = "hotstring_editor", epoch = first })
				helpers.assert_nil(routed)
				helpers.assert_eq(direct.saved, false)
				helpers.assert_eq(f.read(), bytes)
				Manager.route_message("hotstring_editor", "hsEditor", "ready", second)
				local fresh = Manager.route_message("hotstring_editor", "hsEditor", {
					action = "save", data = opening_model("new managed opening") }, second)
				helpers.assert_eq(fresh.saved, true)
			end)
			Manager.hide("hotstring_editor", Manager.current_epoch("hotstring_editor"))
			Manager.build_page_html, Manager._create_gtk_window, Manager.eval_js = html, creator, evaluate
			package.loaded["core.ui.ui.webview_manager"] = port
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("missing committed-payload receipt does not invent a next-save source", function()
		with_opening_file(function(f)
			helpers.assert_eq(f.ready(), true)
			local native = f.publisher.write
			f.publisher.write = function(...)
				local ok, detail = native(...)
				return ok, detail
			end
			local result = f.save("physically saved without payload ACK")
			helpers.assert_eq(result.saved, false)
			helpers.assert_true(f.read():find('physically saved without payload ACK', 1, true) ~= nil)
			helpers.assert_eq(f.seen.reloads, 0)
			f.publisher.write = native
			helpers.assert_eq(f.save("cannot invent authority").saved, false)
			helpers.assert_eq(f.ready(), true)
			helpers.assert_eq(f.save("reopened actual bytes").saved, true)
		end)
	end)

	helpers.it("a failed reentrant opening cannot be revived by an older write ACK", function()
		with_opening_file(function(f)
			helpers.assert_eq(f.ready(), true)
			local native = f.publisher.write
			local reentered
			f.publisher.write = function(...)
				local ok, detail, payload = native(...)
				f.seen.delivery = "false"
				reentered = f.ready()
				return ok, detail, payload
			end
			local result = f.save("accepted old write")
			helpers.assert_eq(reentered, false)
			helpers.assert_eq(result.saved, false)
			helpers.assert_eq(f.seen.reloads, 0)
			helpers.assert_true(f.read():find('accepted old write', 1, true) ~= nil)
			f.publisher.write = native
			helpers.assert_eq(f.save("must reopen").saved, false)
		end)
	end)
end)

