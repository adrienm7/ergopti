--- tests/unit/modules/keylogger/test_physical_media_metrics.lua

--- Independent identities and real SQLite; native capture endpoints remain software models.
local h = require("tests.helpers")
local Identity = require("modules.keylogger.physical_key_identity")
local Metric = require("keylogger.hid_metric_identity")

-- Literal expectations from Apple IOHIDUsageTables.h, not the implementation.
local vectors = {
	{ 0xCD, "PLAY", 4295753933 }, { 0xB5, "NEXT", 4295753909 }, { 0xB6, "PREVIOUS", 4295753910 },
	{ 0x6F, "BRIGHTNESS_UP", 4295753839 }, { 0x70, "BRIGHTNESS_DOWN", 4295753840 },
}

local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end

-- Only the init argument is observed; refusal prevents native source ownership.
local function captured_port(managed)
	local module_name = "modules.keylogger.physical_history_session"
	local noop = function() end
	local selected, acquisitions
	acquisitions = 0
	local overrides = {
		["adapters.physical_history_context"] = { new = noop },
		["adapters.physical_observation_clock"] = { bind_history_scope = noop },
		["modules.keylogger.physical_capture"] = { init = function(ports) selected = ports.keycode; return false end,
			bind_history_scope = noop, stop = noop, bind_managed_source = function() acquisitions = acquisitions + 1 end },
		["modules.keylogger"] = { bind_physical_configuration_observer = noop, bind_physical_lifecycle_observer = noop,
			may_persist = noop },
		["modules.keylogger.context_tracker"] = { bind_physical_correlated_context_observer = noop, sample_physical_context = noop },
		["modules.keylogger.watchers"] = { bind_physical_lifecycle_observer = noop },
		["modules.shortcuts.script_control"] = { bind_physical_pause_observer = noop },
		["adapters.shell_runner"] = { spawn = noop },
		["adapters.timer_scheduler"] = { after = noop, cancel = noop, onSettled = noop },
		["modules.keylogger.physical_key_identity"] = { resolve = Identity.resolve },
		["modules.keylogger.log_manager"] = { log_physical_press = noop, log_physical_release = noop },
	}
	local saved, previous_hs = {}, hs
	for name, value in pairs(overrides) do saved[name] = package.loaded[name]; package.loaded[name] = value end
	saved[module_name] = package.loaded[module_name]; package.loaded[module_name] = nil
	hs = { json = { encode = noop, decode = noop } }
	local ok, result = pcall(function()
		local owner, reason = require(module_name).init(32, noop, managed and { managed = true } or nil)
		h.assert_eq(owner, nil)
		h.assert_eq(reason, "physical_history_capture_already_initialized")
		h.assert_eq(acquisitions, 0)
		return selected
	end)
	hs = previous_hs
	for name in pairs(overrides) do package.loaded[name] = saved[name] end
	package.loaded[module_name] = saved[module_name]
	if not ok then error(result) end
	return result
end

h.describe("explicit shared media metrics identity", function()
	h.it("credits the five approved HID usages without changing virtual keycode resolution", function()
		for _, vector in ipairs(vectors) do
			h.assert_eq(Metric.resolve_hid(12, vector[1]), vector[3])
			h.assert_eq(Identity.resolve_metric(12, vector[1], "none"), vector[3])
			local virtual, reason = Identity.resolve(12, vector[1], "ansi")
			h.assert_eq(virtual, nil); h.assert_eq(reason, "unmapped_usage")
			h.assert_eq(tonumber(tostring(vector[3])), vector[3])
			h.assert_eq(tonumber(string.format("%d", vector[3])), vector[3])
		end
	end)

	h.it("shares exact public system-key names without accepting numeric NX types or aliases", function()
		for _, vector in ipairs(vectors) do h.assert_eq(Metric.resolve_system_name(vector[2]), vector[3]) end
		for _, name in ipairs({ "play", "Play/Pause", "REWIND", "EJECT", "VOLUME_UP", 16, false, {} }) do
			h.assert_eq(Metric.resolve_system_name(name), nil)
		end
		h.assert_eq(Metric.resolve_system_name(nil), nil)
	end)

	h.it("keeps known platform IDs and keyboard-form refusal reasons", function()
		h.assert_eq(Identity.resolve_metric(7, 4, "ansi"), 0)
		h.assert_eq(Identity.resolve_metric(12, 0xE2, "none"), 74)
		h.assert_eq(Identity.resolve_metric(7, 0x35, "iso"), 10)
		local key, reason = Identity.resolve_metric(7, 0x35, "jis")
		h.assert_eq(key, nil); h.assert_eq(reason, "unsupported_keyboard_type")
	end)

	h.it("rejects invalid HID fields and usages outside the narrow whitelist", function()
		for _, invalid in ipairs({ -1, 65536, 0.5, math.huge, -math.huge, "205", false, {} }) do
			h.assert_eq(Metric.resolve_hid(12, invalid), nil)
			h.assert_eq(Metric.resolve_hid(invalid, 205), nil)
		end
		h.assert_eq(Metric.resolve_hid(12, 0/0), nil); h.assert_eq(Metric.resolve_hid(0/0, 205), nil)
		h.assert_eq(Metric.resolve_hid(nil, 205), nil); h.assert_eq(Metric.resolve_hid(12, nil), nil)
		h.assert_eq(Metric.resolve_hid(7, 205), nil); h.assert_eq(Metric.resolve_hid(65535, 205), nil)
		for _, usage in ipairs({ 0, 0xB0, 0xB1, 0xCF, 65535 }) do
			h.assert_eq(Metric.resolve_hid(12, usage), nil)
			local key, reason = Identity.resolve_metric(12, usage, "ansi")
			h.assert_eq(key, nil); h.assert_eq(reason, "unmapped_usage")
		end
	end)

	h.it("retains the captured resolver and its zero ID, arguments and original reasons", function()
		local calls = 0
		local wrapped = Metric.with_virtual_keycodes(function(page, usage, form)
			calls = calls + 1
			h.assert_eq({ page, usage, form }, { 12, 205, "iso" })
			return 0, "preserved"
		end)
		local key, reason = wrapped(12, 205, "iso")
		h.assert_eq(key, 0); h.assert_eq(reason, "preserved"); h.assert_eq(calls, 1)
		local missing = Metric.with_virtual_keycodes(function() return nil, "unsupported" end)
		h.assert_eq(missing(12, 205, "none"), 4295753933)
		local absent, refusal = missing(12, 176, "none")
		h.assert_eq(absent, nil); h.assert_eq(refusal, "unsupported")
		local accepted, reason = pcall(Metric.with_virtual_keycodes, nil)
		h.assert_eq(accepted, false)
		h.assert_eq(type(reason), "string")
		h.assert_eq(reason:match("Missing virtual keycode resolver$"), "Missing virtual keycode resolver")
	end)

	h.it("selects shared metrics only for managed History and preserves the legacy resolver pointer", function()
		local managed, legacy = captured_port(true), captured_port(false)
		h.assert_eq(type(managed), "function")
		for _, vector in ipairs(vectors) do h.assert_eq(managed(12, vector[1], "ansi"), vector[3]) end
		h.assert_eq(managed(7, 4, "ansi"), 0)
		h.assert_eq(rawequal(legacy, Identity.resolve), true)
		local missing, reason = managed(12, 176, "ansi")
		h.assert_eq(missing, nil); h.assert_eq(reason, "unmapped_usage")
	end)

	h.it("persists delivered media and recovers independent totals through two real SQLite rebuilds", function()
		local root = h.driver_root() .. "../../.."
		local fixture = h.driver_root() .. "tests/support/physical_media_sqlite.lua"
		local script = [[
import importlib.util,json,os,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]).resolve()
spec=importlib.util.spec_from_file_location("owned_media",root/"tools/diagnostics/hs274_persistence_test.py")
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);m.ROOT=root
os.environ["ERGOPTI_PHYSICAL_SOURCE_ROOT"]=str(root)
os.environ.pop("ERGOPTI_MEDIA_RESOLVER",None)
with tempfile.TemporaryDirectory(prefix="ergopti-media-metrics-") as temporary:
 receipt=m.run_fixture(sys.argv[2],temporary,Path(sys.argv[3]).resolve())
 keys=[0,4295753839,4295753840,4295753909,4295753910,4295753933]
 presses=[{"keycode":key,"c":1,"kind":"integer"} for key in keys]
 holds=[{"keycode":key,"sum_ms":300,"count":1,"max_ms":300,"tap_count":0,"hold_count":1,"kind":"integer"} for key in keys]
 if receipt["native"] is not False: raise AssertionError("Fixture is not native qualification")
 if "numeric" in receipt:
  if receipt["numeric"]!={"holds":holds,"presses":presses}: raise AssertionError(receipt)
 else:
  for hold in holds: hold.update(date="2026-10-07",app="Original")
  for phase in ("live","rebuild_one","rebuild_two"):
   observed=receipt[phase]
   if observed["holds"]!=holds or observed["presses"]!=presses: raise AssertionError(observed)
   raw=observed["raw"]
   if len(raw)!=12: raise AssertionError(raw)
   for index,key in enumerate([0,4295753933,4295753909,4295753910,4295753839,4295753840]):
    for offset,action in enumerate(("physical_press","physical_release")):
     entry=raw[index*2+offset]
     expected={"app":"Original","capture":"capture-media","device":"18446744073709551615","keycode":key}
     if offset: expected["hold_ms"]=300
     if entry["action"]!=action or json.loads(entry["metadata_json"])!=expected: raise AssertionError(entry)
  expected_unknown=[{"count":1,"keyboard_type":"ansi","page":12,"reason":"unmapped_usage","usage":176}]
  if receipt["uncounted"]!=expected_unknown: raise AssertionError(receipt["uncounted"])
print("PASS: literal media identities, integer SQLite rows and retained storage totals")
]]
		local executable = os.getenv("LUA") or arg[-1]
		h.assert_eq(type(executable), "string")
		local command = "python3 -c " .. quote(script) .. " " .. quote(root) .. " " .. quote(executable) .. " " .. quote(fixture) .. " 2>&1"
		local pipe = assert(io.popen(command, "r"))
		local output = pipe:read("*a")
		local ok, kind, status = pipe:close()
		h.assert_eq(ok, true, output); h.assert_eq(kind, "exit", output); h.assert_eq(status, 0, output)
		h.assert_eq(output, "PASS: literal media identities, integer SQLite rows and retained storage totals\n")
	end)
end)
