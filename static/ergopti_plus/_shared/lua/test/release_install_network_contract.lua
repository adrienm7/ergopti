--- _shared/lua/test/release_install_network_contract.lua

--- Shared Versions failure-receipt and action lifecycle regression controls.
--- Native I/O is controlled; classification uses the actual canonical policy.
local M = {}

function M.register(helpers, policy)
	local Install = require("updater.release_install")
	local contract = require("network.failure").new(policy)
	local function fixture()
		local state = { live = true, blocked = nil, calls = {}, reports = {}, report_owners = {}, callbacks = {}, diagnostics = false }
		local native = {}
		local function call(name) state.calls[#state.calls + 1] = name end
		local logger = {}
		for _, name in ipairs({ "error", "warn", "start", "success" }) do logger[name] = function() end end
		logger.error = function() if state.on_error then state.on_error() end end
		logger.success = function() if state.on_success then state.on_success() end end
		local session = Install.new({ logger = logger,
			acceptance_owner = function() return state.acceptance_document or native end,
			acceptance_current = function(owner)
				if state.on_acceptance then state.on_acceptance() end
				return owner == (state.acceptance_document or native) and state.live
			end,
			blocked = function() if state.on_blocked then state.on_blocked() end; return state.blocked end,
			find_release = function(tag) call("find"); if state.on_find then state.on_find() end; return { tag = tag } end,
			backup = function() call("backup"); if state.on_backup then state.on_backup() end; return { path = "/private/backup" } end,
			resolve_asset = function() call("asset"); if state.on_asset then state.on_asset() end; return { digest = "independently-pinned" } end,
			download = function(_, _, done) call("download"); state.callbacks[#state.callbacks + 1] = done; return true end,
			install = function() call("install"); if state.on_install then state.on_install() end; return true end,
			restart = function() call("restart"); if state.on_restart then state.on_restart() end; return true end,
			report = function(message, owner) state.reports[#state.reports + 1] = message; state.report_owners[#state.reports] = owner; if state.on_report then state.on_report(message) end end,
			failure_contract = function()
				if state.on_contract then state.on_contract() end
				return not state.disable_policy and contract or nil
			end,
			failure_owner = function() if state.on_owner then state.on_owner() end; return state.native_owner or native end,
			failure_current = function(owner)
				if state.on_current then state.on_current() end
				return owner == native and state.live
			end,
			failure_capabilities = function()
				if state.on_capabilities then state.on_capabilities() end
				if state.probe_fault then error("private native probe failure") end
				return { diagnostics_available = state.diagnostics }
			end,
			failure_action = function(id) call(id); return true end,
		})
		state.session = session
		function state.fail(receipt, reason)
			state.callbacks[#state.callbacks](nil, reason or Install.REASON.download, "private proxy credential", receipt)
			return state.reports[#state.reports]
		end
		return state
	end
	local function proxy() return { stage = "proxy_connect", failure_provenance = "verified", proxy_connect_status = 407 } end
	local function fail(state, receipt)
		helpers.assert_eq(state.session.install("v1.2.3", "dev"), true)
		return state.fail(receipt)
	end
	local function action(state, message, id)
		return state.session.failure_action(message.operation, message.failure_epoch, id)
	end
	helpers.describe("Versions managed network receipt ownership", function()
		helpers.it("classifies typed proxy evidence without exposing native secrets", function()
			local state = fixture()
			local receipt = proxy(); receipt.url, receipt.stderr, receipt.path = "https://token@host", "secret", "/private/file"
			local message = fail(state, receipt)
			helpers.assert_eq(message.failure_report.cause, "proxy")
			helpers.assert_eq(message.failure_report.message_key, "network.failure.proxy")
			helpers.assert_eq(message.failure_report.receipt, nil)
			helpers.assert_eq(message.failure_report.url, nil)
			helpers.assert_eq(message.failure_report.stderr, nil)
			helpers.assert_eq(message.failure_report.path, nil)
			helpers.assert_eq(message.detail, nil)
			helpers.assert_eq(message.failure_receipt, nil)
			helpers.assert_eq(message.backup_path, "/private/backup")
			helpers.assert_eq(table.concat(state.calls, ","), "find,backup,asset,download")
		end)
		helpers.it("keeps untyped adapter errors unknown despite hostile detail", function()
			local state = fixture(); local message = fail(state, nil)
			helpers.assert_eq(message.failure_report.cause, "unknown")
			helpers.assert_eq(message.failure_report.evidence, "insufficient_evidence")
		end)
		helpers.it("never treats an unproved origin 407 as proxy evidence", function()
			local state = fixture()
			local message = fail(state, { stage = "http", failure_provenance = "verified", http_status = 407 })
			helpers.assert_eq(message.failure_report.cause, "unknown")
		end)
		helpers.it("keeps failed verification separate and never installs", function()
			local state = fixture(); state.session.install("v1.2.3", "dev")
			local message = state.fail(proxy(), Install.REASON.verify)
			helpers.assert_eq(message.reason_key, Install.REASON.verify)
			helpers.assert_eq(message.failure_report, nil)
			helpers.assert_eq(table.concat(state.calls, ","), "find,backup,asset,download")
		end)
		helpers.it("requires exact operation and failure epoch before retry", function()
			local state = fixture(); local message = fail(state, proxy())
			helpers.assert_eq(state.session.failure_action(message.operation + 1, message.failure_epoch, "retry"), false)
			helpers.assert_eq(state.session.failure_action(message.operation, message.failure_epoch + 1, "retry"), false)
			helpers.assert_eq(#state.callbacks, 1)
		end)
		helpers.it("retry reruns backup-first and duplicate old callbacks cannot install", function()
			local state = fixture(); local message = fail(state, proxy()); local old = state.callbacks[1]
			helpers.assert_eq(action(state, message, "retry"), true)
			helpers.assert_eq(table.concat(state.calls, ","), "find,backup,asset,download,find,backup,asset,download")
			old("/old/verified")
			helpers.assert_eq(table.concat(state.calls, ","), "find,backup,asset,download,find,backup,asset,download")
			helpers.assert_eq(action(state, message, "retry"), false)
			state.callbacks[2]("/new/verified")
			helpers.assert_eq(table.concat(state.calls, ","), "find,backup,asset,download,find,backup,asset,download,install,restart")
		end)
		helpers.it("new same-tag failure rejects the previous terminal owner", function()
			local state = fixture(); local first = fail(state, proxy())
			helpers.assert_eq(action(state, first, "retry"), true)
			local second = state.fail(proxy())
			helpers.assert_eq(second.operation > first.operation, true)
			helpers.assert_eq(second.failure_epoch > first.failure_epoch, true)
			helpers.assert_eq(action(state, first, "retry"), false)
			helpers.assert_eq(action(state, second, "retry"), true)
		end)
		helpers.it("rechecks actual owner and build policy after failure", function()
			local state = fixture(); local message = fail(state, proxy())
			state.live = false; helpers.assert_eq(action(state, message, "retry"), false)
			state.live = true; state.blocked = "source"; helpers.assert_eq(action(state, message, "retry"), false)
			helpers.assert_eq(#state.callbacks, 1)
		end)
		helpers.it("recomputes real external capability and never takes a page path", function()
			local state = fixture(); state.diagnostics = true; local message = fail(state, proxy())
			state.diagnostics = false; helpers.assert_eq(action(state, message, "diagnostics"), false)
			state.diagnostics = true; helpers.assert_eq(action(state, message, "diagnostics"), true)
			helpers.assert_eq(state.calls[#state.calls], "diagnostics")
		end)
		helpers.it("reentrant native capability probe cannot lend a retired owner", function()
			local state = fixture(); local message = fail(state, proxy())
			state.on_current = function() state.session.retire() end
			helpers.assert_eq(action(state, message, "retry"), false)
			helpers.assert_eq(#state.callbacks, 1)
		end)
		helpers.it("native probe failure preserves the failed phase without unbound actions", function()
			local state = fixture(); state.probe_fault = true; local message = fail(state, proxy())
			helpers.assert_eq(message.phase, "failed")
			helpers.assert_eq(message.managed_failure, true)
			helpers.assert_eq(message.failure_report, nil)
			helpers.assert_eq(state.session.failure_action(1, 1, "retry"), false)
			helpers.assert_eq(message.backup_path, "/private/backup")
		end)
		local function successor_survives(state, hook)
			helpers.assert_eq(state.session.install("v1.2.3", "dev"), true)
			local predecessor = state.callbacks[1]
			state[hook] = function()
				state[hook] = nil
				helpers.assert_eq(state.session.install("v1.2.3", "dev"), true)
			end
			predecessor(nil, Install.REASON.download, "Synthetic failure", proxy())
			helpers.assert_eq(#state.callbacks, 2)
			helpers.assert_eq(state.session.busy(), true)
			helpers.assert_eq(state.reports[#state.reports].phase, "downloading")
			for _, message in ipairs(state.reports) do
				helpers.assert_true(message.phase ~= "failed", "predecessor published into successor")
			end
			local next_failure = state.fail(proxy())
			helpers.assert_eq(next_failure.phase, "failed")
			helpers.assert_eq(action(state, next_failure, "retry"), true)
			helpers.assert_eq(#state.callbacks, 3)
		end
		helpers.it("native owner inspection cannot resurrect a retired reservation", function()
			local state = fixture()
			state.on_owner = function() state.session.retire() end
			helpers.assert_eq(state.session.install("v1.2.3", "dev"), false)
			helpers.assert_eq(state.session.busy(), false)
			helpers.assert_eq(#state.callbacks, 0)
			helpers.assert_eq(#state.reports, 0)
		end)
		helpers.it("contract loading cannot publish a predecessor into a same-tag successor", function()
			successor_survives(fixture(), "on_contract")
		end)
		helpers.it("capability inspection cannot retire or publish into a successor", function()
			successor_survives(fixture(), "on_capabilities")
		end)
		helpers.it("current-owner inspection cannot replace a successor terminal", function()
			successor_survives(fixture(), "on_current")
		end)
		helpers.it("contract loading cannot restore publication after exact page retirement", function()
			local state = fixture()
			state.session.install("v1.2.3", "dev")
			state.on_contract = function() state.session.retire() end
			state.callbacks[1](nil, Install.REASON.download, "Synthetic failure", proxy())
			helpers.assert_eq(state.session.busy(), false)
			helpers.assert_eq(state.reports[#state.reports].phase, "downloading")
			helpers.assert_eq(state.session.failure_action(1, 1, "retry"), false)
		end)
		helpers.it("policy-error logging cannot publish an obsolete failed phase", function()
			local state = fixture(); state.session.install("v1.2.3", "dev")
			state.disable_policy = true
			state.on_error = function()
				if state.session.busy() then return end
				state.on_error = nil; state.disable_policy = false
				helpers.assert_eq(state.session.install("v1.2.3", "dev"), true)
			end
			state.callbacks[1](nil, Install.REASON.download, "Synthetic failure", proxy())
			helpers.assert_eq(#state.callbacks, 2)
			helpers.assert_eq(state.session.busy(), true)
			helpers.assert_eq(state.reports[#state.reports].phase, "downloading")
			local next_failure = state.fail(proxy())
			helpers.assert_eq(action(state, next_failure, "retry"), true)
		end)
		helpers.it("keeps the original private report owner outside the public payload", function()
			local state = fixture(); local original = {}; state.native_owner = original
			state.session.install("v1.2.3", "dev")
			state.native_owner = {}
			local message = state.fail(proxy())
			helpers.assert_eq(state.report_owners[#state.reports], original)
			helpers.assert_eq(message.native_owner, nil)
			helpers.assert_eq(message.document_owner, nil)
		end)
		helpers.it("retires the exact failed reservation when native owner inspection throws", function()
			local state = fixture()
		state.on_owner = function() error("controlled native owner fault") end
			helpers.assert_eq(state.session.install("v1.2.3", "dev"), false)
			helpers.assert_eq(state.session.busy(), false)
			helpers.assert_eq(#state.callbacks, 0)
			helpers.assert_eq(state.reports[#state.reports].reason_key, Install.REASON.unexpected)
		end)
		helpers.it("cannot publish or clear a successor when owner fault logging reenters", function()
			local state = fixture()
		state.on_owner = function() error("controlled native owner fault") end
			state.on_error = function()
				state.on_owner, state.on_error = nil, nil
				helpers.assert_eq(state.session.install("v1.2.3", "dev"), true)
			end
			helpers.assert_eq(state.session.install("v1.2.3", "dev"), false)
			helpers.assert_eq(state.session.busy(), true)
			helpers.assert_eq(#state.callbacks, 1)
			helpers.assert_eq(state.reports[#state.reports].phase, "downloading")
		end)
		for _, port in ipairs({ "report", "backup", "asset", "install", "success", "restart" }) do
			helpers.it("page retirement during " .. port .. " preserves accepted native transaction without later publication", function()
				local state = fixture()
				state["on_" .. port] = function()
					state["on_" .. port] = nil; state.session.retire()
				end
				helpers.assert_eq(state.session.install("v1.2.3", "dev"), true)
				state.callbacks[1]("/owned/verified", nil, nil)
				helpers.assert_eq(table.concat(state.calls, ","), "find,backup,asset,download,install,restart")
				local forbidden = ({report="downloading",backup="downloading",asset="downloading",install="restarting",success="restarting",restart="failed"})[port]
				for _, message in ipairs(state.reports) do helpers.assert_eq(message.phase == forbidden, false) end
			end)
		end
		for _, port in ipairs({ "blocked", "find" }) do
			helpers.it("reentrant " .. port .. " cannot overwrite a successor reservation before backup", function()
				local state = fixture()
				state["on_" .. port] = function()
					state["on_" .. port] = nil
					helpers.assert_eq(state.session.install("v2.0.0", "dev"), true)
				end
				helpers.assert_eq(state.session.install("v1.2.3", "dev"), false)
				helpers.assert_eq(#state.callbacks, 1)
				helpers.assert_eq(state.session.busy(), true)
				helpers.assert_eq(state.reports[#state.reports].tag, "v2.0.0")
			end)
		end
		for _, port in ipairs({ "blocked", "find" }) do
			helpers.it("retirement during pre-acceptance " .. port .. " refuses old work but permits fresh successor", function()
				local state = fixture()
				state["on_" .. port] = function() state["on_" .. port] = nil; state.session.retire() end
				helpers.assert_eq(state.session.install("v1.2.3", "dev"), false)
				helpers.assert_eq(#state.callbacks, 0)
				helpers.assert_eq(state.session.busy(), false)
				helpers.assert_eq(state.session.install("v2.0.0", "dev"), true)
			end)
			helpers.it("native document replacement during " .. port .. " cannot borrow pre-acceptance", function()
				local state = fixture(); state.acceptance_document = {}
				state["on_" .. port] = function() state["on_" .. port] = nil; state.acceptance_document = {} end
				helpers.assert_eq(state.session.install("v1.2.3", "dev"), false)
				helpers.assert_eq(#state.callbacks, 0)
				helpers.assert_eq(state.session.install("v2.0.0", "dev"), true)
			end)
		end
		helpers.it("retires action authority on close without cancelling native work", function()
			local state = fixture(); local message = fail(state, proxy())
			state.session.retire(); helpers.assert_eq(action(state, message, "retry"), false)
			helpers.assert_eq(#state.callbacks, 1)
		end)
	end)
end

return M
