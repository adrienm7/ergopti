--- tests/meta/harness/test_document_fixture_transactional.lua

--- ==============================================================================
--- MODULE: Document Fixture Transactional Construction
--- DESCRIPTION:
--- tests/support/document_fixture.lua replaces lgi, the timings registry, the
--- event loop, the notifiers, the WebKit host and the webview manager in
--- package.loaded before it opens a window. When construction failed partway,
--- those doubles stayed installed: the timings double refuses every key but one,
--- so a single fixture failure made about 1200 later Linux tests fail. A failed
--- construction must leave every entry exactly as it found it.
--- ==============================================================================

local helpers = require("tests.helpers")
local DocumentFixture = require("tests.support.document_fixture")

local SWAPPED = {
	"lgi", "infra.monotonic", "infra.timings", "infra.managed_http_deadline",
	"adapters.event_loop", "adapters.notifier", "adapters.application_notifier",
	"ui.webkit_host", "ui.webview_manager",
}

--- Records the current package.loaded value of each swapped name.
--- @param extra string[] Further names to record.
--- @return table snapshot { [name] = { value } }
local function snapshot(extra)
	local values = {}
	for _, name in ipairs(SWAPPED) do values[name] = { value = package.loaded[name] } end
	for _, name in ipairs(extra) do values[name] = { value = package.loaded[name] } end
	return values
end

--- Asserts that every recorded entry is the same object again.
--- @param before table Snapshot from snapshot().
local function assert_restored(before)
	for name, entry in pairs(before) do
		helpers.assert_true(rawequal(package.loaded[name], entry.value),
			"package.loaded['" .. name .. "'] must be restored after a failed construction")
	end
end

helpers.describe("document fixture: transactional construction", function()
	helpers.it("restores every double when the manager refuses the window", function()
		-- An empty application name passes every swap, then Manager.show refuses it.
		local before = snapshot({ "ui..bridge" })
		local ok, detail = pcall(DocumentFixture.new, "", { bridge_name = "fixture" }, nil)
		helpers.assert_eq(ok, false, "the refused window must fail the construction")
		helpers.assert_true(tostring(detail):find("controlled native window", 1, true) ~= nil,
			"the original failure is rethrown: " .. tostring(detail))
		assert_restored(before)
	end)

	helpers.it("restores every double when the state cannot be copied", function()
		local before = snapshot({ "ui.transactional_probe.bridge" })
		local ok = pcall(DocumentFixture.new, "transactional_probe", { bridge_name = "fixture" }, 42)
		helpers.assert_eq(ok, false, "a state that is not a table must fail the construction")
		assert_restored(before)
	end)

	helpers.it("leaves the real timings registry usable after a failure", function()
		pcall(DocumentFixture.new, "", { bridge_name = "fixture" }, nil)
		local Timings = require("infra.timings")
		local read_ok, timeout_ms = pcall(Timings.ms, "ui", "document_initialization_ack_timeout_ms")
		helpers.assert_true(read_ok and type(timeout_ms) == "number" and timeout_ms > 0,
			"the real registry still answers: " .. tostring(timeout_ms))
		helpers.assert_true(package.loaded.lgi == nil or package.loaded.lgi.WebKit2 == nil
			or package.loaded.lgi.WebKit2.WebView == nil
			or debug.getinfo(package.loaded.lgi.WebKit2.WebView, "S").source:find("document_fixture", 1, true) == nil,
			"the fixture's lgi double is not left installed")
	end)
end)
