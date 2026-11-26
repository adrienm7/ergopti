--- tests/meta/harness/test_keyring_proof_readiness.lua

--- ==============================================================================
--- MODULE: Keyring Proof Readiness Guard
--- DESCRIPTION:
--- The real keyring proof (tests/hardware/run_keyring_receipts.sh) hung until
--- its 5-minute step timeout in CI run 45247903986: its first secret-tool call
--- came before the unlocked gnome-keyring-daemon claimed
--- org.freedesktop.secrets, so the bus activated a second daemon. That one
--- inherited the bus's XDG_RUNTIME_DIR, missed the first daemon's control
--- socket, and opened a prompt to create a login keyring that nobody answers.
--- The hardware step needs a real keyring, so these cases pin the three
--- guards in the runner's text: the bus starts with the private runtime
--- directory, the proof waits for the name owner, and the proof is bounded.
--- ==============================================================================

local helpers = require("tests.helpers")

local RUNNER = helpers.driver_root() .. "/tests/hardware/run_keyring_receipts.sh"

--- Reads the runner's text.
--- @return string
local function runner_text()
	local handle = assert(io.open(RUNNER, "rb"), "the keyring proof runner is missing: " .. RUNNER)
	local body = handle:read("*a")
	handle:close()
	return body
end

helpers.describe("keyring proof readiness (keyring-proof-activation-race-2026-11-23)", function()
	helpers.it("starts the session bus with the private runtime directory", function()
		local body = runner_text()
		-- The bus hands its own environment to the services it activates.
		local launch = body:match("([^\n]*\\\n[^\n]*dbus%-run%-session[^\n]*)")
			or body:match("([^\n]*dbus%-run%-session[^\n]*)")
		helpers.assert_true(launch ~= nil, "the runner starts a private session bus")
		helpers.assert_true(launch:find('XDG_RUNTIME_DIR="${WORK}/run"', 1, true) ~= nil,
			"dbus-run-session inherits the private XDG_RUNTIME_DIR: " .. tostring(launch))
		local inside = body:sub((body:find("--inside\" ]; then", 1, true) or 1))
		inside = inside:sub((inside:find("\nfi\n", 1, true) or 1))
		helpers.assert_true(not inside:find("export XDG_RUNTIME_DIR", 1, true),
			"the runtime directory is not changed after the bus has started")
	end)

	helpers.it("waits for the unlocked daemon to own the secret service before the proof", function()
		local body = runner_text()
		local unlock = body:find("gnome-keyring-daemon --unlock", 1, true)
		local wait = body:find("org.freedesktop.DBus.NameHasOwner org.freedesktop.secrets", 1, true)
		local proof = body:find("luajit tests/hardware/run_keyring_receipts.lua", 1, true)
		helpers.assert_true(unlock and wait and proof, "unlock, owner wait and proof are all present")
		helpers.assert_true(unlock < wait and wait < proof, "the owner wait sits between the unlock and the proof")
		helpers.assert_true(body:find('[ "${owned}" != "(true,)" ]', 1, true) ~= nil,
			"a name never claimed fails the run instead of continuing")
	end)

	helpers.it("bounds the proof so an unanswered prompt fails with a message", function()
		local body = runner_text()
		helpers.assert_true(body:find("timeout -k 5 120 luajit tests/hardware/run_keyring_receipts.lua", 1, true) ~= nil,
			"the proof runs under a deadline")
		helpers.assert_true(body:find("the keyring proof exceeded 120 s", 1, true) ~= nil,
			"an expired deadline names itself")
	end)
end)
