--- _shared/lua/test/config_reset_failure_contract.lua

--- ==============================================================================
--- MODULE: Reset Failure Message Contract
--- DESCRIPTION:
--- Drives the real scope composition into each refusal a global restore or
--- clear can meet and proves the report names the typed failure point the
--- Windows reset names, and that the message every Lua driver shows is the
--- reason of that point in every locale. Before, macOS refused in silence and
--- Linux said « it has been reverted » for a rollback that was still pending.
--- ==============================================================================

return function(helpers, json, shared_root)
	local Manifest = require("infra.manifest_reader")
	local Composition = require("config_scope_composition")
	local ResetFailure = require("config_reset_failure")

	--- Reads one shared JSON file.
	--- @param relative string Path under the shared root.
	--- @return table decoded
	local function read_json(relative)
		local file = assert(io.open(shared_root .. "/" .. relative, "rb"))
		local text = file:read("*a")
		file:close()
		return json.decode(text)
	end

	local EN = read_json("data/locales/en.json")

	--- English lookup that refuses a key the locale lacks.
	local function english(key)
		return assert(EN[key], "missing English string " .. key)
	end

	--- A logger double that discards every line.
	local function silent_logger()
		local logger = {}
		for _, level in ipairs({ "start", "success", "info", "warn", "error" }) do logger[level] = function() end end
		return logger
	end

	--- A participant whose refusals the case chooses.
	--- @param behaviour table|nil refuse, refuse_revert, refuse_release, debt.
	local function participant(behaviour)
		behaviour = behaviour or {}
		local stub, committed = {}, false
		function stub.apply(_, done)
			if behaviour.refuse then return done(false, "refused") end
			committed = true
			return done(true)
		end
		function stub.revert(done)
			if behaviour.refuse_revert then return done(false, "revert refused") end
			committed = false
			return done(true)
		end
		function stub.release()
			if behaviour.refuse_release then return false end
			committed = false
		end
		function stub.pending() return behaviour.debt == true end
		function stub.retry_restore(done) return done(false) end
		stub.committed = function() return committed end
		return stub
	end

	--- Runs one composition request and returns its refused report.
	local function refused(registry, mode)
		local owner = Composition.new({ manifest = Manifest, scope = "global", logger = silent_logger(),
			participants = function() return registry end })
		local settled = {}
		owner.apply(mode or "recommended", function(ok, report) settled.ok, settled.report = ok, report end)
		helpers.assert_eq(settled.ok, false, "the request is refused")
		return settled.report, owner
	end

	helpers.describe("reset failure: typed points of the global scope", function()
		helpers.it("names commit when a category refused and every committed one was reverted", function()
			local report = refused({ tap_holds = participant(), llm = participant({ refuse = true }) })
			helpers.assert_eq({ report.point, report.kind, report.failed }, { "commit", "refused", "llm" })
			local title, message = ResetFailure.message(report, english)
			helpers.assert_eq(title, EN["dialog.reset_defaults.failed_title"])
			helpers.assert_eq(message, "Reset failed.\n\nReason: The reset transaction could not be committed (llm/refused).")
		end)

		helpers.it("names rollback, never a revert, when the revert itself was refused", function()
			local report = refused({ tap_holds = participant({ refuse_revert = true }), llm = participant({ refuse = true }) })
			helpers.assert_eq({ report.point, report.kind, report.failed }, { "rollback", "rollback_pending", "llm" })
			local _, message = ResetFailure.message(report, english)
			helpers.assert_true(message:find("could not be restored (llm/rollback_pending)", 1, true) ~= nil, message)
			helpers.assert_true(message:find(EN["dialog.bulk_toggle.save_failed"], 1, true) == nil,
				"the generic reverted text is gone")
		end)

		helpers.it("names acquire while a category or the composition still owns a transaction", function()
			local report = refused({ tap_holds = participant(), gestures = participant({ debt = true }) }, "clear")
			helpers.assert_eq({ report.point, report.kind, report.failed }, { "acquire", "retained_debt", "gestures" })
			local _, message = ResetFailure.message(report, english)
			helpers.assert_true(message:find("exclusive ownership (gestures/retained_debt)", 1, true) ~= nil, message)
			local _, owner = refused({ tap_holds = participant({ refuse_revert = true }), llm = participant({ refuse = true }) })
			local blocked
			owner.apply("clear", function(_, second) blocked = second end)
			helpers.assert_eq({ blocked.point, blocked.kind, blocked.failed }, { "acquire", "pending", nil })
			_, message = ResetFailure.message(blocked, english)
			helpers.assert_true(message:find("(global/pending)", 1, true) ~= nil, "the composite scope is named: " .. message)
		end)

		helpers.it("names finalize when the values were applied but a backup could not be forgotten", function()
			local report = refused({ tap_holds = participant(), llm = participant({ refuse_release = true }) })
			helpers.assert_eq({ report.point, report.kind, report.failed }, { "finalize", "release_refused", "llm" })
			local _, message = ResetFailure.message(report, english)
			helpers.assert_true(message:find("The values were applied", 1, true) ~= nil, message)
		end)

		helpers.it("names commit for a request the composition cannot run", function()
			local report = refused({ tap_holds = participant() }, "factory")
			helpers.assert_eq({ report.point, report.kind }, { "commit", "unknown_mode" })
			report = refused({ unknown_scope = participant() })
			helpers.assert_eq({ report.point, report.kind }, { "commit", "unresolved" })
		end)

		helpers.it("raises on a refused report that names no typed point", function()
			local ok = pcall(ResetFailure.message, { scope = "global", detail = "free text" }, english)
			helpers.assert_eq(ok, false, "a guessed reason is never shown")
		end)

		helpers.it("translates every reason in every locale with its placeholders", function()
			local locales = read_json("data/locale_order.json").order
			helpers.assert_eq(#locales, 21)
			for _, locale in ipairs(locales) do
				local strings = read_json("data/locales/" .. locale .. ".json")
				helpers.assert_true(type(strings[ResetFailure.TITLE_KEY]) == "string", locale .. ": title")
				helpers.assert_true(strings[ResetFailure.MESSAGE_KEY]:find("{1}", 1, true) ~= nil, locale .. ": message")
				for point, key in pairs(ResetFailure.REASON_KEYS) do
					local reason = strings[key]
					helpers.assert_true(type(reason) == "string", locale .. ": " .. point)
					helpers.assert_true(reason:find("{1}", 1, true) ~= nil and reason:find("{2}", 1, true) ~= nil,
						locale .. ": " .. point .. " names the scope and the kind")
				end
			end
		end)
	end)
end
