--- tests/hardware/run_keyring_receipts.lua

--- ==============================================================================
--- MODULE: API Keys in a Real Secret Service, Locked and Unlocked
--- DESCRIPTION:
--- Run by run_keyring_receipts.sh inside a private session bus with a real
--- gnome-keyring-daemon, an X server and its unlock prompter (gcr-prompter).
--- Drives the production modules/llm/api_token_store.lua through the real
--- secret-tool, never a stand-in:
---   1. unlocked: a key is stored and read back byte for byte (UTF-8, and the
---      8192-byte stdin capacity exactly), a longer key is refused with no
---      reference, the stored item carries the application attribute;
---   2. locked, the unlock prompt answered with the password: the lookup the
---      daemon makes at start returns the key;
---   3. locked, the prompt dismissed: no key, and a reason that is not
---      "absent", so the entry is kept as unreadable rather than missing;
---   4. a clear on the locked keyring removes nothing and is refused (it
---      asks for no unlock); once unlocked, cleared, the next lookup reads
---      "absent".
--- The prompt is answered by typing into the real prompter window (xdotool).
--- Usage: luajit run_keyring_receipts.lua <keyring password>
--- ==============================================================================

local Store = require("modules.llm.api_token_store")
local Shell = require("adapters.shell_runner")

local PASSWORD = assert(arg[1], "usage: run_keyring_receipts.lua <keyring password>")
for _, program in ipairs({ "secret-tool", "gdbus" }) do
	assert(Shell.exec_checked("command -v " .. program), program .. " is required")
end
local CAPACITY = 8192

local checks, failures = 0, 0
local function check(condition, text)
	checks = checks + 1
	if not condition then failures = failures + 1 end
	print((condition and "  ok   " or "  FAIL ") .. text)
	return condition
end

local function lock()
	return Shell.run("gdbus call --session --dest org.freedesktop.secrets --object-path /org/freedesktop/secrets"
		.. " --method org.freedesktop.Secret.Service.Lock \"['/org/freedesktop/secrets/collection/login']\" >/dev/null")
end

--- Starts a background answer to the next unlock prompt: the password and
--- Return, or Escape to dismiss it.
local function answer_prompt(dismiss)
	local keys = dismiss and "xdotool key Escape"
		or ("xdotool type --delay 80 " .. Shell.quote(PASSWORD) .. "; sleep 0.5; xdotool key Return")
	return Shell.run("(for i in $(seq 80); do w=$(xdotool search --onlyvisible --class gcr-prompter 2>/dev/null | head -1);"
		.. " [ -n \"$w\" ] && break; sleep 0.25; done; [ -n \"$w\" ] || exit 1; sleep 2;"
		.. " xdotool windowactivate --sync \"$w\"; xdotool windowfocus --sync \"$w\"; sleep 1; " .. keys
		.. ") >/dev/null 2>&1 &")
end

print("=== API keys in a real secret service ===")
local key = "sk-live-é-" .. string.rep("x", 32)
local reference, why = Store.store("live", key)
check(Store.is_reference(reference), "an unlocked keyring stores the key: " .. tostring(reference or why))
local _, found = Shell.exec_checked("secret-tool search application ErgoptiPlus 2>/dev/null")
found = type(found) == "string" and found or ""
check(found:find("label = ErgoptiPlus API key live#", 1, true) ~= nil, "secret-tool search lists the stored item")
local tokens, reasons = Store.lookup_many({ reference })
check(tokens[reference] == key, "the key reads back byte for byte: " .. tostring(reasons[reference]))

local full = string.rep("k", CAPACITY)
local full_reference = Store.store("full", full)
local full_tokens = Store.lookup_many({ full_reference })
check(full_reference ~= nil and full_tokens[full_reference] == full, "a key of exactly 8192 bytes reads back whole")
local over_reference, over_why = Store.store("over", full .. "k")
check(over_reference == nil and tostring(over_why):find("capacity", 1, true) ~= nil,
	"a longer key is refused, with no reference: " .. tostring(over_why))

check(lock(), "the login collection is locked")
answer_prompt(false)
tokens, reasons = Store.lookup_many({ reference })
check(tokens[reference] == key, "locked, the prompt answered: the key is returned: " .. tostring(reasons[reference]))

check(lock(), "the login collection is locked again")
answer_prompt(true)
tokens, reasons = Store.lookup_many({ reference })
check(tokens[reference] == nil, "locked, the prompt dismissed: no key is returned")
check(type(reasons[reference]) == "string" and reasons[reference] ~= "absent" and reasons[reference] ~= "",
	"the dismissal is a failure, not an absent key: " .. tostring(reasons[reference]))

-- secret-tool clear asks for no unlock: on a locked keyring it removes
-- nothing and exits 1 silently, which used to read as cleared.
local locked_cleared, locked_why = Store.clear(reference)
check(locked_cleared == false and tostring(locked_why):find("stays in the secret service", 1, true) ~= nil,
	"a clear on the locked keyring is refused, not reported done: " .. tostring(locked_why))
-- Without --all, search lists only the first match: name the exact item.
local _, still = Shell.exec_checked("secret-tool search application ErgoptiPlus api_key "
	.. Shell.quote(reference:sub(#Store.REFERENCE_PREFIX + 1)) .. " 2>/dev/null")
check(type(still) == "string" and still:find("label = ErgoptiPlus API key live#", 1, true) ~= nil,
	"and the item is still in the keyring")
answer_prompt(false)
tokens = Store.lookup_many({ reference })
check(tokens[reference] == key, "unlocked again through the prompt")
check(Store.clear(reference) == true, "the key is cleared on the unlocked keyring")
tokens, reasons = Store.lookup_many({ reference })
check(tokens[reference] == nil and reasons[reference] == "absent", "a cleared key reads absent: " .. tostring(reasons[reference]))
Store.clear(full_reference)

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
