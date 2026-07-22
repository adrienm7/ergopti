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
	return (driver_root or ".") .. "/../kanata/kanata.kbd"
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

	helpers.it("passes pointer inputs through transparently on every layer", function()
		local text = read_template()
		local src_tokens = tokens(form_body(text, "defsrc") or "")
		local pointer_positions = {}
		for index, token in ipairs(src_tokens) do
			for _, pointer in ipairs(POINTER_INPUTS) do
				if token == pointer then pointer_positions[pointer] = index end
			end
		end

		local checked_layers = 0
		for layer_name, body in text:gmatch("%(deflayer%s+(%S+)%s+(.-)%)") do
			local layer_tokens = tokens(body)
			helpers.assert_eq(#src_tokens, #layer_tokens,
				"deflayer " .. layer_name .. " must stay aligned with defsrc")
			for _, pointer in ipairs(POINTER_INPUTS) do
				local index = pointer_positions[pointer]
				helpers.assert_true(index ~= nil, "missing pointer position: " .. pointer)
				helpers.assert_eq("_", layer_tokens[index],
					"deflayer " .. layer_name .. " must transparently pass " .. pointer)
			end
			checked_layers = checked_layers + 1
		end
		helpers.assert_true(checked_layers >= 2, "expected default and navigation layers")
	end)
end)

