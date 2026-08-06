--- linux/tests/unit/meta/test_kanata_pointer_interrupts.lua

--- ==============================================================================
--- MODULE: Kanata Pointer-Interrupt Tap-Hold Regression Tests
--- DESCRIPTION:
--- Locks down the Linux equivalent of the AHK/Karabiner invariant: wheel and
--- mouse-button inputs are processed transparently by Kanata, so every pending
--- tap-hold-press resolves to hold instead of emitting its tap on release.
--- ==============================================================================

local helpers = require("tests.helpers")

local function template_path()
	local src = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
	local driver_root = src:match("^(.*)/tests/unit/meta/[^/]+$")
	return (driver_root or ".") .. "/platform/remap/data/kanata.kbd"
end

local function read_template()
	local path = template_path()
	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, "cannot read kanata template: " .. path)
	local text = fh:read("*a")
	fh:close()
	return text
end

local function tokens(body)
	body = body:gsub(";;[^\r\n]*", "")
	local out = {}
	for token in body:gmatch("%S+") do out[#out + 1] = token end
	return out
end

local function form_body(text, head)
	return text:match("%(" .. head .. "%s+(.-)%)")
end

local POINTER_INPUTS = {
	"mwu", "mwd", "mwl", "mwr",
	"mlft", "mrgt", "mmid", "mbck", "mfwd",
}

helpers.describe("kanata pointer activity cancels pending tap-holds", function()
	helpers.it("keeps process-unmapped-keys enabled for all keyboard interruptions", function()
		local text = read_template()
		helpers.assert_true(
			text:find("process%-unmapped%-keys%s+yes") ~= nil,
			"unmapped keyboard input must participate in tap-hold-press resolution"
		)
	end)

	helpers.it("declares every wheel direction and mouse button as a physical input", function()
		local text = read_template()
		local body = form_body(text, "defsrc")
		helpers.assert_true(body ~= nil, "kanata template must contain defsrc")
		local seen = {}
		for _, token in ipairs(tokens(body)) do seen[token] = true end
		for _, pointer in ipairs(POINTER_INPUTS) do
			helpers.assert_true(seen[pointer] == true,
				"defsrc must process pointer interrupt: " .. pointer)
		end
	end)

	helpers.it("passes every pointer input through on the default layer", function()
		-- The DEFAULT layer is where the invariant lives, and it is unchanged. A
		-- tap-hold can still be pending here — that is the whole point of the
		-- pointer inputs being in defsrc — so anything but transparency would
		-- both change what the wheel does and interfere with the resolution.
		local text = read_template()
		local src_tokens = tokens(form_body(text, "defsrc") or "")
		local layer_tokens = tokens(text:match("%(deflayer%s+default%s+(.-)%)") or "")
		helpers.assert_eq(#src_tokens, #layer_tokens, "the default layer must align with defsrc")

		local checked = 0
		for index, token in ipairs(src_tokens) do
			for _, pointer in ipairs(POINTER_INPUTS) do
				if token == pointer then
					checked = checked + 1
					helpers.assert_eq("_", layer_tokens[index],
						"the default layer must transparently pass " .. pointer)
				end
			end
		end
		helpers.assert_eq(checked, #POINTER_INPUTS, "every pointer input must be checked")
	end)

	helpers.it("keeps the mouse buttons transparent on every layer", function()
		-- Buttons, not the wheel. A held layer that swallows the click the user
		-- is about to make is worse than one that does less: a dead middle-click
		-- has no visible cause and no obvious way to relate it to a key being
		-- held on the other hand.
		--
		-- The wheel is deliberately not covered here. The navigation layer is
		-- reached by HOLDING a dual-role key, so by the time it is active that
		-- key's tap-hold has already resolved — a wheel event on it cannot
		-- influence a decision that has been made. Being in defsrc is what makes
		-- a pointer event an interruption; its OUTPUT on an already-held layer is
		-- a separate question, and this file used to conflate the two.
		local BUTTONS = { "mlft", "mrgt", "mmid", "mbck", "mfwd" }
		local text = read_template()
		local src_tokens = tokens(form_body(text, "defsrc") or "")

		local checked_layers = 0
		for layer_name, body in text:gmatch("%(deflayer%s+(%S+)%s+(.-)%)") do
			local layer_tokens = tokens(body)
			helpers.assert_eq(#src_tokens, #layer_tokens,
				"deflayer " .. layer_name .. " must stay aligned with defsrc")
			for index, token in ipairs(src_tokens) do
				for _, button in ipairs(BUTTONS) do
					if token == button then
						helpers.assert_eq("_", layer_tokens[index],
							"deflayer " .. layer_name .. " must transparently pass " .. button)
					end
				end
			end
			checked_layers = checked_layers + 1
		end
		helpers.assert_true(checked_layers >= 2, "expected default and navigation layers")
	end)

	helpers.it("puts volume on the wheel while navigation is held", function()
		-- The positive half of the change above. Narrowing the transparency rule
		-- without asserting what replaced it would leave the wheel free to become
		-- anything at all, including nothing.
		local text = read_template()
		local src_tokens = tokens(form_body(text, "defsrc") or "")
		local layer_tokens = tokens(text:match("%(deflayer%s+navigation%s+(.-)%)") or "")

		local expected = { mwu = "volu", mwd = "vold" }
		local checked = 0
		for index, token in ipairs(src_tokens) do
			if expected[token] then
				checked = checked + 1
				helpers.assert_eq(expected[token], layer_tokens[index],
					token .. " must produce " .. expected[token] .. " on the navigation "
						.. "layer: a layer that remaps the whole keyboard left the one "
						.. "input the hand is already on doing exactly what it does "
						.. "unmodified")
			end
		end
		helpers.assert_eq(checked, 2, "both wheel directions must be checked")
	end)
end)

