--- _shared/lua/test/personal_model_contract.lua

--- ==============================================================================
--- MODULE: Personal Editor Model Contract
--- DESCRIPTION:
--- Calls hotstrings/personal_model.prepare directly. The writer corpus
--- (personal_editor_preservation.json) replays the preserved-source vectors
--- through the acknowledged writer; this contract owns what that path cannot
--- reach: the admission of the opening source and of the editor model, each with
--- its own refusal code, and the candidate built for a source that does not
--- exist yet. Both Lua drivers publish the personal files through it.
--- ==============================================================================

local M = {}

--- Registers the contract cases.
--- @param helpers table The driver's test helpers.
function M.register(helpers)
	local Personal = require("hotstrings.personal_model")
	local Codec = require("toml_codec")

	--- One editor row with every flag spelled.
	local function row(trigger, output, overrides)
		local entry = { trigger = trigger, output = output, is_word = true, auto_expand = false,
			is_case_sensitive = false, final_result = false }
		for key, value in pairs(overrides or {}) do entry[key] = value end
		return entry
	end

	--- A valid one-section model.
	local function model(entries)
		return { sections_order = { "words" }, sections = { words = { description = "Words", entries = entries } } }
	end

	local ABSENT = { status = "absent" }

	--- Asserts one refusal: no candidate and the named code.
	local function refuses(source, editor_model, code)
		local candidate, refusal = Personal.prepare(source, editor_model)
		helpers.assert_nil(candidate, code)
		helpers.assert_eq(refusal, code)
	end

	helpers.describe("personal editor model (personal-model-contract)", function()
		helpers.it("(personal-model-contract) refuses an opening source or model it cannot admit, with one code each", function()
			refuses(nil, model({}), "invalid-personal-model")
			refuses({ status = "changed", content = "" }, model({}), "invalid-personal-model")
			refuses(ABSENT, nil, "invalid-personal-model")
			refuses(ABSENT, { sections = {} }, "invalid-personal-model")
			refuses(ABSENT, { sections_order = {} }, "invalid-personal-model")
			refuses({ status = "ok" }, model({}), "unreadable-personal-source")
			refuses({ status = "ok", content = "[[words\nbroken" }, model({}), "malformed-personal-source")
			refuses({ status = "ok", content = "[_META]\nx = 1\n" }, model({}), "ambiguous-personal-metadata")
		end)

		helpers.it("(personal-model-contract) refuses a model whose sections are not exactly the ordered ones", function()
			refuses(ABSENT, { sections_order = { "words", "words" }, sections = { words = { entries = {} } } },
				"invalid-personal-section")
			refuses(ABSENT, { sections_order = { "" }, sections = { [""] = { entries = {} } } }, "invalid-personal-section")
			refuses(ABSENT, { sections_order = { "words" }, sections = {} }, "invalid-personal-section")
			refuses(ABSENT, { sections_order = { "words" }, sections = { words = "text" } }, "invalid-personal-section")
			refuses(ABSENT, { sections_order = { "words" }, sections = { words = { entries = {} }, extra = { entries = {} } } },
				"unlisted-personal-section")
		end)

		helpers.it("(personal-model-contract) refuses a row the file could not read back as written", function()
			refuses(ABSENT, { sections_order = { "words" }, sections = { words = { description = "W" } } }, "invalid-personal-row")
			refuses(ABSENT, model({ row("", "x") }), "invalid-personal-row")
			refuses(ABSENT, model({ row("a", 1) }), "invalid-personal-row")
			refuses(ABSENT, model({ row("a", "x"), row("a", "y") }), "invalid-personal-row")
			refuses(ABSENT, model({ row("a", "x", { is_word = "yes" }) }), "invalid-personal-row")
			refuses(ABSENT, model({ row("a", "x", { priority = "high" }) }), "invalid-personal-row")
		end)

		helpers.it("(personal-model-contract) builds the whole file for a source that does not exist yet", function()
			local candidate, refusal = Personal.prepare(ABSENT, model({ row("hello", "Salut"), row("bye", "Adieu", { is_word = false }) }))
			helpers.assert_nil(refusal)
			local decoded = Codec.decode(candidate)
			helpers.assert_eq(decoded.words[1].hello.output, "Salut")
			helpers.assert_eq(decoded.words[1].hello.is_word, true)
			helpers.assert_eq(decoded.words[1].bye.is_word, false)
			helpers.assert_eq(decoded._meta.sections_order, { "words" })
			helpers.assert_eq(decoded._meta.sections.words, "Words", "the displayed description is stored")
			helpers.assert_true(candidate:find("[[words]]", 1, true) ~= nil)
		end)

		helpers.it("(personal-model-contract) applies the caller's normaliser to the stored output only", function()
			local candidate = Personal.prepare(ABSENT, model({ row("hello", "Salut") }), function(value) return value:upper() end)
			helpers.assert_eq(Codec.decode(candidate).words[1].hello.output, "SALUT")
		end)

		helpers.it("(personal-model-contract) rewrites only the projected row and keeps foreign metadata and comments", function()
			local source = table.concat({
				"[_meta]",
				"description = \"Owned by the user\"",
				"future_flag = true",
				"sections_order = [\"words\"]",
				"[_meta.sections.words]",
				"description = \"Words\"",
				"future = \"kept\"",
				"# Standalone comment.",
				"[[words]]",
				"\"hello\" = { output = \"Bonjour\", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false } # Row comment.",
				"",
			}, "\n")
			local candidate, refusal = Personal.prepare({ status = "ok", content = source }, model({ row("hello", "Salut") }))
			helpers.assert_nil(refusal)
			for _, kept in ipairs({ "future_flag = true", "future = \"kept\"", "# Standalone comment.",
				"Owned by the user", "# Row comment." }) do
				helpers.assert_true(candidate:find(kept, 1, true) ~= nil, kept .. " must survive the rewrite")
			end
			helpers.assert_eq(Codec.decode(candidate).words[1].hello.output, "Salut")
			helpers.assert_eq(candidate:find("Bonjour", 1, true), nil, "the replaced output is gone")
			local unchanged = Personal.prepare({ status = "ok", content = source }, model({ row("hello", "Bonjour") }))
			helpers.assert_eq(unchanged, source, "a model equal to the source rewrites nothing")
		end)

		helpers.it("(personal-model-contract) keeps a deleted row's trailing comment and drops the row", function()
			local source = table.concat({
				"[_meta]",
				"sections_order = [\"words\"]",
				"[[words]]",
				"\"hello\" = { output = \"Bonjour\", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false } # Row comment.",
				"\"bye\" = { output = \"Adieu\", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }",
				"",
			}, "\n")
			local candidate, refusal = Personal.prepare({ status = "ok", content = source }, model({ row("bye", "Adieu") }))
			helpers.assert_nil(refusal)
			local decoded = Codec.decode(candidate)
			helpers.assert_eq(#decoded.words, 1)
			helpers.assert_eq(decoded.words[1].bye.output, "Adieu")
			helpers.assert_eq(candidate:find("Bonjour", 1, true), nil)
			helpers.assert_true(candidate:find("# Row comment.", 1, true) ~= nil, "the deleted row's comment is the user's")
		end)
	end)
end

return M
