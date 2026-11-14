--- tests/unit/adapters/network/test_pac_runtime.lua

--- ==============================================================================
--- MODULE: Owned PAC Evaluation
--- DESCRIPTION:
--- GIO and libproxy 0.5 keep only the "METHOD host" entries of a PAC answer,
--- so "PROXY a; DIRECT" reached the managed Ollama walk without its DIRECT
--- fallback (TODO « Linux PAC lists through GIO »). The lookup child now runs
--- the PAC itself; these cases pin the answer parser that turns the whole list
--- into the receipt, the destination host handed to FindProxyForURL and the
--- refusal when the engine is missing. The real engine runs in the container
--- proof (tests/hardware/run_owned_ollama_container.py, PacEngine), whose CI
--- lane installs it; the unit lanes do not ship it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Paths = require("core.fs.engine.paths")

local function runtime() return helpers.fresh_module("platform.network.pac_runtime") end

local LIMITS = { max_heap_bytes = 67108864, max_native_queries = 128, max_output_bytes = 65536, max_selections = 128 }

--- The shared helper source the Windows worker embeds too.
--- @return string
local function shared_helpers()
	local file = assert(io.open(assert(Paths.shared("core/network/data/pac_helpers.js")), "rb"))
	local text = file:read("*a")
	assert(file:close())
	return text
end

helpers.describe("owned PAC evaluation: the whole ordered list (linux-pac-evaluation)", function()
	helpers.it("keeps DIRECT after a relay, in order, in the receipt's URI form", function()
		local proxies = runtime().parse_answer("PROXY a.corp:3128; DIRECT", 128)
		helpers.assert_eq(#proxies, 2)
		helpers.assert_eq(proxies[1], "http://a.corp:3128")
		helpers.assert_eq(proxies[2], "direct://")
	end)
	helpers.it("maps every method GIO maps and ignores one trailing separator", function()
		local proxies = runtime().parse_answer(" HTTPS b:443 ;SOCKS c:1080; SOCKS5 [::1]:9;socks4 d:1; proxy e:8;", 128)
		helpers.assert_eq(table.concat(proxies, " "),
			"https://b:443 socks5://c:1080 socks5://[::1]:9 socks4://d:1 http://e:8")
	end)
	helpers.it("refuses the whole answer for an entry it cannot honor rather than dropping it", function()
		local Runtime = runtime()
		for _, answer in ipairs({ "PROXY a:1; FTP b:2", "PROXY a", "PROXY a:0", "PROXY a:70000", "PROXY a:1;; DIRECT",
			"", "PROXY a:1\nDIRECT", "PROXY a/b:1", "PROXY user@a:1" }) do
			helpers.assert_nil(Runtime.parse_answer(answer, 128), answer)
		end
	end)
	helpers.it("refuses an answer over the shared selection bound", function()
		helpers.assert_nil(runtime().parse_answer("DIRECT; PROXY a:1; PROXY b:2", 2))
		helpers.assert_eq(#runtime().parse_answer("DIRECT; PROXY a:1", 2), 2)
	end)
	helpers.it("hands FindProxyForURL the destination host without userinfo, port or brackets", function()
		local Runtime = runtime()
		helpers.assert_eq(Runtime.host_of("https://Registry.Ollama.AI/v2/library"), "registry.ollama.ai")
		helpers.assert_eq(Runtime.host_of("https://user:secret@host.corp:8443/x"), "host.corp")
		helpers.assert_eq(Runtime.host_of("http://[2001:db8::1]:80/"), "2001:db8::1")
		helpers.assert_nil(Runtime.host_of("not a url"))
	end)
	helpers.it("refuses with the closed engine code when the engine library is absent", function()
		local Runtime = helpers.load_module_with_dependency("platform.network.pac_runtime", "_generated.native_runtime",
			{ network_runtime = { pac_engine = "libergopti-absent-engine.so.0" } })
		local proxies, refusal = Runtime.evaluate('function FindProxyForURL(u, h) { return "DIRECT"; }',
			shared_helpers(), "https://registry.ollama.ai/", LIMITS)
		helpers.assert_nil(proxies)
		helpers.assert_eq(refusal, Runtime.ENGINE_UNAVAILABLE)
	end)
end)
