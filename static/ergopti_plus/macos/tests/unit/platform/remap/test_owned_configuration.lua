--- tests/unit/platform/remap/test_owned_configuration.lua

--- Exercises exact private publication capabilities; filesystem ports are modeled.
local h = require("tests.helpers")

--- Makes native publication receipts over real shared callback lifetimes.
local function fixture()
	local P = require("remap.owned_configuration_publication")
	local d = { owner = {}, token = {}, active = true, stopped = false, bytes = "personal", writes = 0,
		settled = true, match = true, published = true, calls = {} }
	local source = {}
	function source.identity(owner) if rawequal(owner, d.owner) then return d.token end end
	function source.current(owner, token)
		if d.current_hook then d.current_hook() end
		return rawequal(owner, d.owner) and rawequal(token, d.token) and d.active
	end
	function source.route(owner, token)
		if rawequal(owner, d.owner) and rawequal(token, d.token) then return "/private/karabiner/karabiner.json" end
	end
	function source.detach(owner, token)
		d.calls[#d.calls + 1] = "detach"
		if d.detach_hook then d.detach_hook() end
		if rawequal(owner, d.owner) and rawequal(token, d.token) and not d.detach_refused then
			d.active, d.stopped = false, true; return true
		end
		return false
	end
	function source.retired(owner, token)
		return rawequal(owner, d.owner) and rawequal(token, d.token) and d.stopped
	end
	local ports = {}
	function ports.build(input)
		d.calls[#d.calls + 1] = "build"
		if d.build_hook then d.build_hook() end
		return input
	end
	function ports.encode(input) return input.bytes end
	function ports.prepare() return true end
	function ports.read() return { status = "ok", content = d.bytes } end
	function ports.write(path, bytes, expected, diagnostic)
		d.writes = d.writes + 1
		if d.write_hook then d.write_hook() end
		local receipt = {}
		function receipt.matches_source() return d.match end
		function receipt.is_settled() return d.settled end
		function receipt.retry()
			d.calls[#d.calls + 1] = "retry"
			if d.retry_hook then d.retry_hook() end
			return d.settled
		end
		d.receipt, d.expected, d.diagnostic = receipt, expected, diagnostic
		d.bytes = bytes
		return d.write_ack ~= false, "native-detail", receipt
	end
	function ports.receipt_view(receipt, path, expected, bytes, diagnostic)
		if d.view_hook then d.view_hook() end
		if rawequal(receipt, d.receipt) and rawequal(expected, d.expected)
			and rawequal(diagnostic, d.diagnostic) and not d.view_refused then
			return { published = d.published, source = { status = "ok", content = bytes } }
		end
	end
	function ports.on_error(category) d.error = category end
	d.source, d.ports = source, ports
	d.publisher = assert(P.new(d.owner, source, ports))
	return d
end

h.describe("private owned configuration publication", function()
	h.it("publishes complete bytes through exact native receipt and snapshot", function()
		local d = fixture()
		h.assert_eq(d.publisher.identity(d.owner), d.token)
		h.assert_eq(d.publisher.publish(d.owner, d.token, { bytes = "complete" }), true)
		h.assert_eq(d.bytes, "complete"); h.assert_eq(d.writes, 1)
		h.assert_eq(d.expected.status, "ok"); h.assert_eq(d.expected.content, "personal")
		h.assert_eq(d.publisher.detach(d.owner, d.token), true)
		h.assert_eq(d.publisher.retired(d.owner, d.token), true)
	end)
	for _, operation in ipairs({ "publish", "detach", "retired" }) do
		h.it("refuses a foreign owner or token for " .. operation, function()
			local d = fixture()
			h.assert_eq(d.publisher[operation]({}, d.token, { bytes = "foreign" }), false)
			h.assert_eq(d.publisher[operation](d.owner, {}, { bytes = "foreign" }), false)
			h.assert_eq(d.writes, 0); h.assert_eq(d.stopped, false)
		end)
	end
	h.it("does not invoke equality hooks to admit foreign tokens", function()
		local d = fixture()
		local foreign = setmetatable({}, { __eq = function() error("foreign equality") end })
		h.assert_eq(d.publisher.publish(d.owner, foreign, { bytes = "foreign" }), false)
		h.assert_eq(d.writes, 0)
	end)
	for _, name in ipairs({ "identity", "current", "route", "detach", "retired" }) do
		h.it("refuses replaced exact source method " .. name, function()
			local d = fixture(); d.source[name] = function() return true end
			h.assert_eq(d.publisher.publish(d.owner, d.token, { bytes = "foreign" }), false)
			h.assert_eq(d.writes, 0)
		end)
	end
	h.it("literal current authority is required", function()
		local d = fixture(); d.active = 1
		h.assert_eq(d.publisher.publish(d.owner, d.token, { bytes = "foreign" }), false)
		h.assert_eq(d.writes, 0)
	end)
	h.it("revocation during build cannot reach native publication", function()
		local d = fixture(); d.build_hook = function() d.active = false end
		h.assert_eq(d.publisher.publish(d.owner, d.token, { bytes = "stale" }), false)
		h.assert_eq(d.writes, 0)
	end)
	h.it("a nested publish cannot claim its outer operation", function()
		local d = fixture()
		d.build_hook = function()
			h.assert_eq(d.publisher.publish(d.owner, d.token, { bytes = "nested" }), false)
		end
		h.assert_eq(d.publisher.publish(d.owner, d.token, { bytes = "outer" }), true)
		h.assert_eq(d.bytes, "outer"); h.assert_eq(d.writes, 1)
	end)
	h.it("stop during a foreign getter revokes before any write", function()
		local d = fixture(); local once = false
		d.current_hook = function()
			if not once then
				once = true
				h.assert_eq(d.publisher.detach(d.owner, d.token), true)
				h.assert_eq(d.publisher.retired(d.owner, d.token), false)
			end
		end
		h.assert_eq(d.publisher.publish(d.owner, d.token, { bytes = "stale" }), false)
		h.assert_eq(d.writes, 0); h.assert_eq(d.publisher.retired(d.owner, d.token), true)
	end)
	h.it("preserves actual cleanup debt after native publication refusal", function()
		local d = fixture(); d.settled, d.write_ack = false, false
		h.assert_eq(d.publisher.publish(d.owner, d.token, { bytes = "published" }), false)
		h.assert_eq(d.bytes, "published"); h.assert_eq(d.writes, 1)
		h.assert_eq(d.publisher.detach(d.owner, d.token), false)
		h.assert_eq(d.publisher.retired(d.owner, d.token), false)
		local count = #d.calls
		h.assert_eq(d.publisher.retired(d.owner, d.token), false)
		h.assert_eq(#d.calls, count, "retired must not retry cleanup")
		d.settled = true
		h.assert_eq(d.publisher.detach(d.owner, d.token), true)
		h.assert_eq(d.publisher.retired(d.owner, d.token), true)
	end)
	for _, flag in ipairs({ "published", "match", "settled" }) do
		h.it("requires literal native " .. flag .. " proof", function()
			local d = fixture(); d[flag] = 1
			h.assert_eq(d.publisher.publish(d.owner, d.token, { bytes = "candidate" }), false)
			h.assert_eq(d.writes, 1)
		end)
	end
	h.it("requires actual native receipt admission", function()
		local d = fixture(); d.view_refused = true
		h.assert_eq(d.publisher.publish(d.owner, d.token, { bytes = "candidate" }), false)
		h.assert_eq(d.writes, 1)
	end)
	h.it("retains a thrown provider object without stringifying it", function()
		local d = fixture(); local original = {}
		d.build_hook = function() error(original, 0) end
		local accepted, reason, detail = d.publisher.publish(d.owner, d.token, { bytes = "candidate" })
		h.assert_eq(accepted, false); h.assert_eq(reason, "owned_publication_raised")
		h.assert_eq(detail, original); h.assert_eq(d.writes, 0)
	end)
	h.it("cannot report retirement inside retained cleanup callback", function()
		local d = fixture(); d.settled = false
		h.assert_eq(d.publisher.publish(d.owner, d.token, { bytes = "candidate" }), false)
		d.retry_hook = function()
			h.assert_eq(d.publisher.retired(d.owner, d.token), false)
			d.settled = true
		end
		h.assert_eq(d.publisher.detach(d.owner, d.token), true)
		h.assert_eq(d.publisher.retired(d.owner, d.token), true)
	end)
	h.it("source retirement must acknowledge exact physical detach", function()
		local d = fixture(); d.detach_refused = true
		h.assert_eq(d.publisher.detach(d.owner, d.token), false)
		h.assert_eq(d.publisher.retired(d.owner, d.token), false)
		h.assert_eq(d.publisher.publish(d.owner, d.token, { bytes = "revoked" }), false)
		h.assert_eq(d.writes, 0)
		d.detach_refused = false
		h.assert_eq(d.publisher.detach(d.owner, d.token), true)
		h.assert_eq(d.publisher.retired(d.owner, d.token), true)
	end)
--- Permanently refuses a once-stale original publication source.
h.it("stale original authority cannot be resurrected with equal route", function()
	local d = fixture(); d.active = false
	h.assert_eq(d.publisher.publish(d.owner, d.token, { bytes = "stale" }), false)
	d.active = true
	h.assert_eq(d.publisher.publish(d.owner, d.token, { bytes = "revived" }), false)
	h.assert_eq(d.writes, 0)
	h.assert_eq(d.publisher.detach(d.owner, d.token), true)
	h.assert_eq(d.publisher.retired(d.owner, d.token), true)
end)
end)

--- Executes the actual native adapter over modeled directory/process metadata only.
local function with_private_adapter(run)
	h.with_fresh_modules({ "platform.remap.owned_configuration", "adapters.file_system", "platform.remap.generator" }, function()
		local original_hs = hs
		local d = { owner = {}, uid = 501, pid = 42, root = "/private/owned", bytes = nil,
			writes = 0, snapshots = {}, calls = {} }
		local root = d.root
		for index, path in ipairs({ "/", "/private", root, root .. "/karabiner" }) do
			d.snapshots[path] = { dev = 1, ino = index, mode = "directory", uid = path == "/" and 0 or d.uid,
				permissions = (path == root or path == root .. "/karabiner") and "rwx------" or "rwxr-xr-x" }
		end
		local function metadata(path)
			d.calls[#d.calls + 1] = path
			if d.metadata_hook then d.metadata_hook(path) end
			local value = d.snapshots[path]
			if value == nil then return nil end
			local copy = {}; for key, field in pairs(value) do copy[key] = field end
			return copy
		end
		local host = { fs = { symlinkAttributes = metadata, pathToAbsolute = function(path) return path end },
			processInfo = { processID = d.pid }, json = {} }
		function host.json.encode(document, pretty)
			h.assert_eq(pretty, true); return document.bytes
		end
		local generator = {}
		function generator.build_karabiner_json(state, actions, keys, combos, non_canonical, data, token)
			d.arguments = { state, actions, keys, combos, non_canonical, data, token }
			return state
		end
		local files = {}
		function files.read_with_status(path, diagnostic)
			h.assert_eq(path, root .. "/karabiner/karabiner.json")
			h.assert_eq(type(diagnostic), "function")
			return d.bytes, d.bytes == nil and "absent" or "ok"
		end
		function files.write_if_unchanged(path, bytes, expected, diagnostic)
			h.assert_eq(path, root .. "/karabiner/karabiner.json")
			h.assert_eq(expected.status, d.bytes == nil and "absent" or "ok")
			h.assert_eq(expected.content, d.bytes)
			d.bytes, d.writes, d.diagnostic, d.expected = bytes, d.writes + 1, diagnostic, expected
			d.snapshots[path] = { mode = "file", uid = d.uid }
			local receipt = { matches_source = function() return true end, is_settled = function() return true end,
				retry = function() return true end }
			d.receipt = receipt
			return true, nil, receipt
		end
		function files.publication_receipt_view(receipt, path, expected, bytes, diagnostic)
			h.assert_eq(receipt, d.receipt); h.assert_eq(expected, d.expected); h.assert_eq(diagnostic, d.diagnostic)
			return { published = true, source = { status = "ok", content = bytes } }
		end
		package.loaded["adapters.file_system"], package.loaded["platform.remap.generator"] = files, generator
		_G.hs = host
		local ok, failure = xpcall(function()
			d.adapter = require("platform.remap.owned_configuration")
			d.host, d.files, d.generator = host, files, generator
			run(d)
		end, debug.traceback)
		_G.hs = original_hs
		if not ok then error(failure, 0) end
	end)
end

h.describe("native private adapter with modeled metadata", function()
	h.it("captures actual generator arguments and fixed complete-publication route", function()
		with_private_adapter(function(d)
			local p = assert(d.adapter.bind_private(d.owner, d.root, d.uid, d.pid))
			local token = p.identity(d.owner)
			local input = { state = { bytes = "complete" }, actions = {}, keys = {}, combos = {},
				non_canonical = {}, data = "unchanged-data", lease_token = "unchanged-generation" }
			h.assert_eq(p.publish(d.owner, token, input), true)
			h.assert_eq(d.bytes, "complete"); h.assert_eq(d.writes, 1)
			for index, key in ipairs({ "state", "actions", "keys", "combos", "non_canonical", "data", "lease_token" }) do
				h.assert_eq(d.arguments[index], input[key])
			end
			h.assert_eq(p.detach(d.owner, token), true); h.assert_eq(p.retired(d.owner, token), true)
		end)
	end)
	for _, mutation in ipairs({ "pid", "root_uid", "child_uid", "root_mode", "child_mode", "parent_link", "final_link", "relative", "alias" }) do
		h.it("refuses native private acquisition with " .. mutation, function()
			with_private_adapter(function(d)
				local root = d.root
				if mutation == "pid" then d.host.processInfo.processID = 43
				elseif mutation == "root_uid" then d.snapshots[root].uid = 502
				elseif mutation == "child_uid" then d.snapshots[root .. "/karabiner"].uid = 502
				elseif mutation == "root_mode" then d.snapshots[root].permissions = "rwxr-xr-x"
				elseif mutation == "child_mode" then d.snapshots[root .. "/karabiner"].permissions = "rwxr-xr-x"
				elseif mutation == "parent_link" then d.snapshots["/private"].mode = "link"
				elseif mutation == "final_link" then d.snapshots[root .. "/karabiner/karabiner.json"] = { mode = "link", uid = d.uid }
				elseif mutation == "relative" then root = "private/owned"
				else d.host.fs.pathToAbsolute = function() return "/private/other" end end
				local p, reason = d.adapter.bind_private(d.owner, root, d.uid, d.pid)
				h.assert_eq(p, nil); h.assert_eq(reason, "owned_private_binding_refused"); h.assert_eq(d.writes, 0)
			end)
		end)
	end
	for _, mutation in ipairs({ "root_ino", "parent_ino", "pid", "metadata", "encoder", "generator", "writer", "receipt_view" }) do
		h.it("revokes native private publication after captured " .. mutation .. " changes", function()
			with_private_adapter(function(d)
				local p = assert(d.adapter.bind_private(d.owner, d.root, d.uid, d.pid)); local token = p.identity(d.owner)
				if mutation == "root_ino" then d.snapshots[d.root].ino = 100
				elseif mutation == "parent_ino" then d.snapshots["/private"].ino = 100
				elseif mutation == "pid" then d.host.processInfo.processID = 43
				elseif mutation == "metadata" then d.host.fs.symlinkAttributes = function() return {} end
				elseif mutation == "encoder" then d.host.json.encode = function() return "foreign" end
				elseif mutation == "generator" then d.generator.build_karabiner_json = function() return {} end
				elseif mutation == "writer" then d.files.write_if_unchanged = function() return true end
				else d.files.publication_receipt_view = function() return {} end end
				h.assert_eq(p.publish(d.owner, token, { state = { bytes = "foreign" } }), false)
				h.assert_eq(d.writes, 0)
				h.assert_eq(p.detach(d.owner, token), true); h.assert_eq(p.retired(d.owner, token), true)
			end)
		end)
	end
end)

h.describe("unadmitted native receipt retirement", function()
	h.it("cannot retire from a settled-looking receipt refused by its real issuer", function()
		local d = fixture(); d.view_refused = true
		h.assert_eq(d.publisher.publish(d.owner, d.token, { bytes = "candidate" }), false)
		h.assert_eq(d.publisher.detach(d.owner, d.token), false)
		h.assert_eq(d.publisher.retired(d.owner, d.token), false)
		for _, call in ipairs(d.calls) do h.assert_true(call ~= "retry", "unadmitted cleanup cannot execute") end
	end)
end)

h.describe("issuer-bound unchanged private publication", function()
	local function unchanged_fixture()
		local d = fixture(); d.published, d.bytes = false, "complete"
		local view = d.ports.receipt_view
		d.ports.receipt_view = function(...)
			local result = view(...)
			if result then result.unchanged = d.unchanged end
			return result
		end
		d.unchanged = true
		-- Capture the new exact port before binding, preserving the original fixture.
		d.publisher = assert(require("remap.owned_configuration_publication").new(d.owner, d.source, d.ports))
		return d
	end
	h.it("admits only an actual unchanged issuer over the original desired bytes", function()
		local d = unchanged_fixture()
		h.assert_eq(d.publisher.publish(d.owner, d.token, {bytes="complete"}), true)
		h.assert_eq(d.writes, 1); h.assert_eq(d.expected.content, "complete")
		h.assert_eq(d.publisher.detach(d.owner, d.token), true)
		h.assert_eq(d.publisher.retired(d.owner, d.token), true)
	end)
	for _, marker in ipairs({false, 1, "true"}) do
		h.it("refuses a nonliteral unchanged issuer marker " .. tostring(marker), function()
			local d = unchanged_fixture(); d.unchanged = marker
			h.assert_eq(d.publisher.publish(d.owner, d.token, {bytes="complete"}), false)
		end)
	end
	h.it("equal bytes without an unchanged issuer marker provide no authority", function()
		local d = unchanged_fixture(); d.unchanged = nil
		h.assert_eq(d.publisher.publish(d.owner, d.token, {bytes="complete"}), false)
	end)
	h.it("the unchanged issuer cannot acknowledge bytes absent from the original source", function()
		local d = unchanged_fixture(); d.bytes = "personal"
		h.assert_eq(d.publisher.publish(d.owner, d.token, {bytes="complete"}), false)
		h.assert_eq(d.publisher.detach(d.owner, d.token), false)
		h.assert_eq(d.publisher.retired(d.owner, d.token), false)
	end)
	h.it("an unknown no-op receipt cannot release original cleanup debt", function()
		local d = unchanged_fixture(); d.view_refused = true
		h.assert_eq(d.publisher.publish(d.owner, d.token, {bytes="complete"}), false)
		h.assert_eq(d.publisher.detach(d.owner, d.token), false)
		h.assert_eq(d.publisher.retired(d.owner, d.token), false)
	end)
	h.it("an unchanged receipt still requires the exact current physical source", function()
		local d = unchanged_fixture(); d.match = false
		h.assert_eq(d.publisher.publish(d.owner, d.token, {bytes="complete"}), false)
	end)
	h.it("retains unchanged native debt and retires only after its real cleanup acknowledgement", function()
		local d = unchanged_fixture(); d.settled, d.write_ack = false, false
		h.assert_eq(d.publisher.publish(d.owner, d.token, {bytes="complete"}), false)
		h.assert_eq(d.publisher.detach(d.owner, d.token), false)
		h.assert_eq(d.publisher.retired(d.owner, d.token), false)
		d.retry_hook = function()
			h.assert_eq(d.publisher.retired(d.owner, d.token), false)
			d.settled = true
		end
		h.assert_eq(d.publisher.detach(d.owner, d.token), true)
		h.assert_eq(d.publisher.retired(d.owner, d.token), true)
	end)
	h.it("stop reentered from unchanged receipt admission revokes before final logical acknowledgement", function()
		local d = unchanged_fixture()
		d.view_hook = function()
			h.assert_eq(d.publisher.detach(d.owner, d.token), false)
			h.assert_eq(d.publisher.retired(d.owner, d.token), false)
		end
		h.assert_eq(d.publisher.publish(d.owner, d.token, {bytes="complete"}), false)
		h.assert_eq(d.publisher.detach(d.owner, d.token), true)
		h.assert_eq(d.publisher.retired(d.owner, d.token), true)
	end)
	h.it("a changed source epoch during no-op admission cannot accept or renew the writer", function()
		local d = unchanged_fixture(); d.view_hook = function() d.active = false end
		h.assert_eq(d.publisher.publish(d.owner, d.token, {bytes="complete"}), false)
		h.assert_eq(d.publisher.publish(d.owner, d.token, {bytes="complete"}), false)
		h.assert_eq(d.writes, 1)
	end)
end)

h.describe("final issuer matcher logical reentry fence", function()
	local function final_match_fixture(hook)
		local d = fixture(); d.bytes, d.published = "complete", false
		local write, view = d.ports.write, d.ports.receipt_view
		d.match_calls = 0
		d.ports.write = function(...)
			local written, detail, receipt = write(...)
			local matcher = receipt.matches_source
			receipt.matches_source = function()
				d.match_calls = d.match_calls + 1
				if d.match_calls == 2 then hook(d) end
				return matcher()
			end
			return written, detail, receipt
		end
		d.ports.receipt_view = function(...)
			local result = view(...)
			if result then result.unchanged = true end
			return result
		end
		d.publisher = assert(require("remap.owned_configuration_publication").new(d.owner, d.source, d.ports))
		return d
	end
	h.it("an epoch revoked by the final native matcher cannot acknowledge unchanged bytes", function()
		local d = final_match_fixture(function(owner) owner.active = false end)
		h.assert_eq(d.publisher.publish(d.owner, d.token, {bytes="complete"}), false)
		h.assert_eq(d.match_calls, 2)
		h.assert_eq(d.publisher.publish(d.owner, d.token, {bytes="complete"}), false)
		h.assert_eq(d.writes, 1)
		h.assert_eq(d.publisher.detach(d.owner, d.token), true)
		h.assert_eq(d.publisher.retired(d.owner, d.token), true)
	end)
	h.it("stop inside the final native matcher retains its in-flight callback before retirement", function()
		local d = final_match_fixture(function(owner)
			h.assert_eq(owner.publisher.detach(owner.owner, owner.token), true)
			h.assert_eq(owner.publisher.retired(owner.owner, owner.token), false)
		end)
		h.assert_eq(d.publisher.publish(d.owner, d.token, {bytes="complete"}), false)
		h.assert_eq(d.match_calls, 2)
		h.assert_eq(d.publisher.retired(d.owner, d.token), true)
	end)
end)
