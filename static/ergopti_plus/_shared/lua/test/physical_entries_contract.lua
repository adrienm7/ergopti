--- _shared/lua/test/physical_entries_contract.lua

--- Independent user operations: literal Unicode and ownership outcomes.
return function(helpers, Entries, Model, registry)
	local function catalogue()
		return {
			is_assignable = function(action) return action == "send_text" or action == "select_word" or action == "none" end,
			get_action_parameter_spec = function(action) return action == "send_text" and "text" or nil end,
			validate_action_parameter = function(action, value) return action == "send_text" and type(value) == "string" and value ~= "" end,
			split_action_parameter_key = function(key)
				return type(key) == "string" and key:match("^(.*)__send_text$") or nil, "send_text"
			end,
		}
	end
	local owner = Entries.new(Model.new(registry), catalogue(), {parameter_section="gestures.action_parameters"})
	local function inventory(assignments, parameters) return { assignments = assignments or {}, parameters = parameters or {} } end
	helpers.describe("physical user entries: shared operation contract", function()
		for _, text in ipairs({ "é", "à", "è", "ç", "ù", ",", ".", ":", "★", "💫", "é", "arbitrary Unicode text" }) do
			helpers.it("(physical-entries) Unicode output remains literal: " .. text, function()
				local rows = owner.plan({ operation = "add", slot = "physical_none_KeyJ", action = "send_text", parameter = text }, inventory())
				helpers.assert_eq(rows, {
					{ section = "shortcuts.keyboard", key = "physical_none_KeyJ", value = "send_text", intent="keyboard_assignment" },
					{ section = "gestures.action_parameters", key = "keyboard__physical_none_KeyJ__send_text", value = text },
				})
			end)
		end
		helpers.it("(physical-entries) empty defaults supply no fabricated entry", function()
			local absent = inventory()
			local rows, reason = owner.plan({ operation = "remove", slot = "physical_none_KeyJ" }, absent)
			helpers.assert_nil(rows); helpers.assert_eq(reason, "entry_absent")
			helpers.assert_eq(absent, { assignments = {}, parameters = {} })
		end)
		helpers.it("(physical-entries) None is an entry and Remove is actual absence", function()
			helpers.assert_eq(owner.plan({ operation = "add", slot = "physical_none_KeyJ", action = "none" }, inventory()), {
				{ section = "shortcuts.keyboard", key = "physical_none_KeyJ", value = "none", intent="keyboard_assignment" },
			})
			helpers.assert_eq(owner.plan({ operation = "remove", slot = "physical_none_KeyJ" }, inventory({physical_none_KeyJ="none"})), {
				{ section = "shortcuts.keyboard", key = "physical_none_KeyJ", delete = true },
			})
		end)
		helpers.it("(physical-entries) shared actions require no text parameter", function()
			helpers.assert_eq(owner.plan({ operation = "add", slot = "physical_ctrl_alt_KeyJ", action = "select_word" }, inventory()), {
				{ section = "shortcuts.keyboard", key = "physical_ctrl_alt_KeyJ", value = "select_word", intent="keyboard_assignment" },
			})
		end)
		helpers.it("(physical-entries) removal owns exactly the chosen binding's recognized parameters", function()
			local state = inventory({ physical_none_KeyJ="send_text", physical_none_KeyE="send_text" }, {
				keyboard__physical_none_KeyJ__send_text="★", keyboard__physical_none_KeyE__send_text="é",
				keyboard__physical_none_KeyJ__unknown_action="retain", other_owner__send_text="retain",
			})
			helpers.assert_eq(owner.plan({ operation="remove", slot="physical_none_KeyJ" }, state), {
				{ section="shortcuts.keyboard", key="physical_none_KeyJ", delete=true },
				{ section="gestures.action_parameters", key="keyboard__physical_none_KeyJ__send_text", delete=true },
			})
			helpers.assert_eq(state.parameters.keyboard__physical_none_KeyE__send_text,"é")
			helpers.assert_eq(state.parameters.keyboard__physical_none_KeyJ__unknown_action,"retain")
		end)
		helpers.it("(physical-entries) repositioning carries exact new output in one scope batch", function()
			helpers.assert_eq(owner.plan({ operation="edit",previous_slot="physical_none_KeyJ",slot="physical_shift_KeyE",action="send_text",parameter="★" },
				inventory({physical_none_KeyJ="send_text"},{keyboard__physical_none_KeyJ__send_text="é"})), {
				{section="shortcuts.keyboard",key="physical_none_KeyJ",delete=true},
				{section="gestures.action_parameters",key="keyboard__physical_none_KeyJ__send_text",delete=true},
				{section="shortcuts.keyboard",key="physical_shift_KeyE",value="send_text", intent="keyboard_assignment"},
				{section="gestures.action_parameters",key="keyboard__physical_shift_KeyE__send_text",value="★"},
			})
		end)
		helpers.it("(physical-entries) Linux uses its existing parameter section with identical binding identity", function()
			local linux = Entries.new(Model.new(registry), catalogue(), {parameter_section="gesture_parameters"})
			helpers.assert_eq(linux.plan({operation="add",slot="physical_none_KeyJ",action="send_text",parameter="★"},inventory()), {
				{section="shortcuts.keyboard",key="physical_none_KeyJ",value="send_text", intent="keyboard_assignment"},
				{section="gesture_parameters",key="keyboard__physical_none_KeyJ__send_text",value="★"},
			})
		end)
		local cases = {
			{{operation="add",slot="physical_none_KeyJ",action="send_text"},inventory(),"invalid_parameter"},
			{{operation="add",slot="physical_none_KeyJ",action="send_text",parameter=""},inventory(),"invalid_parameter"},
			{{operation="add",slot="physical_none_KeyJ",action="select_word",parameter="é"},inventory(),"unexpected_parameter"},
			{{operation="add",slot="physical_none_KeyJ",action="unknown"},inventory(),"invalid_action"},
			{{operation="add",slot="physical_none_KeyJ",action="none"},inventory({physical_none_KeyJ="none"}),"entry_exists"},
			{{operation="edit",slot="physical_none_KeyJ",action="none"},inventory(),"entry_absent"},
			{{operation="edit",previous_slot="physical_none_KeyJ",slot="physical_none_KeyE",action="none"},inventory({physical_none_KeyJ="none",physical_none_KeyE="none"}),"entry_exists"},
			{{operation="remove",slot="physical_none_KeyJ",action="none"},inventory({physical_none_KeyJ="none"}),"invalid_request"},
			{{operation="add",slot="physical_none_KeyJ",action="none",previous_slot="physical_none_KeyE"},inventory(),"invalid_previous_slot"},
			{{operation="add",slot="physical_ctrl_ctrl_KeyJ",action="none"},inventory(),"invalid_slot"},
			{{operation="add",slot="physical_none_KeyJ",action="none",dead_key="circumflex"},inventory(),"invalid_request"},
			{{operation="unknown",slot="physical_none_KeyJ"},inventory(),"invalid_operation"},
		}
		for index, row in ipairs(cases) do
			helpers.it("(physical-entries) independently specified refusal "..index, function()
				local operations, reason = owner.plan(row[1],row[2]);helpers.assert_nil(operations);helpers.assert_eq(reason,row[3])
			end)
		end
	end)
end
