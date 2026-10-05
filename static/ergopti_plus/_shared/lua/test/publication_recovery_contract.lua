--- _shared/lua/test/publication_recovery_contract.lua

--- Independent capability doubles validate consumer ordering; these tests do
--- not qualify physical locking, symlinks or the native receipt producer.
local M = {}
local Recovery = require("hotstrings.publication_recovery")

local function fixture()
	local f = { source = "legacy", route = "owned", epoch = 1, settled = false,
		release = false, calls = 0, publications = 0, receipts = {} }
	f.on_error = function() end
	f.files = { publication_receipt_view = function(native, path, expected, candidate, on_error)
		local record = f.receipts[native]
		if not record or path ~= record.path or expected.status ~= record.expected.status
			or expected.content ~= record.expected.content or candidate ~= record.candidate
			or on_error ~= record.on_error then return nil end
		if f.view_hook then f.view_hook() end
		return { published = record.published, source = {
			status = record.published and "ok" or record.expected.status,
			content = record.published and record.candidate or record.expected.content } }
	end }
	function f.receipt(expected, candidate, published, on_error)
		local record = { path = "owned", expected = expected, candidate = candidate,
			published = published, on_error = on_error, settled = false, route = f.route }
		local native = {
			matches_source = function()
				if f.match_hook then f.match_hook() end
				return f.route == record.route and f.source == (published and candidate or expected.content)
			end,
			is_settled = function()
				if f.settled_hook then f.settled_hook() end
				return record.settled
			end,
			retry = function()
				f.calls = f.calls + 1
				if f.retry_hook then f.retry_hook() end
				if f.release then record.settled = not f.lie_settlement; return true end
				return false
			end,
		}
		f.receipts[native] = record
		return native
	end
	function f.lease(native, callback)
		return Recovery.lease({ files = f.files, native = native, path = "owned",
			expected = { status = "ok", content = "legacy" }, candidate = "split",
			on_error = callback or f.on_error, current = function() return f.epoch == 1 end })
	end
	return f
end

function M.register(helpers)
	helpers.describe("common autocorrection retained native publication capabilities", function()
		helpers.it("(common-autocorrection-recovery) requires the actual receipt and exact callback identity", function()
			local f = fixture(); f.source = "split"
			local native = f.receipt({ status = "ok", content = "legacy" }, "split", true, f.on_error)
			helpers.assert_nil(f.lease({}))
			helpers.assert_nil(f.lease(native, function() end))
			local lease = assert(f.lease(native))
			helpers.assert_eq(lease.view(), { published = true, source = { status = "ok", content = "split" } })
			helpers.assert_eq(lease.settle(), false)
			helpers.assert_eq(f.calls, 1)
			f.release = true
			helpers.assert_true(lease.settle())
			helpers.assert_eq(f.calls, 2)
		end)
		helpers.it("(common-autocorrection-recovery) refuses an equal-byte foreign route even after physical settlement", function()
			local f = fixture(); f.source = "split"; f.release = true
			local lease = assert(f.lease(f.receipt({ status = "ok", content = "legacy" }, "split", true, f.on_error)))
			helpers.assert_true(lease.settle())
			f.route = "foreign"
			helpers.assert_eq(lease.settle(), false)
			helpers.assert_eq(f.calls, 1, "no retry is borrowed for the foreign route")
		end)
		helpers.it("(common-autocorrection-recovery) rejects a retry without actual terminal settlement", function()
			local f = fixture(); f.source = "split"; f.release = true; f.lie_settlement = true
			local lease = assert(f.lease(f.receipt({ status = "ok", content = "legacy" }, "split", true, f.on_error)))
			helpers.assert_eq(lease.settle(), false)
			f.lie_settlement = false
			helpers.assert_true(lease.settle())
		end)
		for _, boundary in ipairs({ "view_hook", "match_hook", "settled_hook", "retry_hook" }) do
			helpers.it("(common-autocorrection-recovery) fences consumer reentry at " .. boundary, function()
				local f = fixture(); f.source = "split"; f.release = true
				local lease = assert(f.lease(f.receipt({ status = "ok", content = "legacy" }, "split", true, f.on_error)))
				f[boundary] = function() f.epoch = 2 end
				helpers.assert_eq(lease.settle(), false)
			end)
		end
		helpers.it("(common-autocorrection-recovery) retains release-only ownership without claiming publication", function()
			local f = fixture(); f.release = true
			local lease = assert(f.lease(f.receipt({ status = "ok", content = "legacy" }, "split", false, f.on_error)))
			helpers.assert_eq(lease.view(), { published = false, source = { status = "ok", content = "legacy" } })
			helpers.assert_true(lease.settle())
			helpers.assert_eq(f.source, "legacy")
		end)
		helpers.it("(common-autocorrection-recovery) retains the failed forward and inverse until both physical releases settle", function()
			local f = fixture()
			local writer = {
				read_classified = function() return f.source, "ok" end,
				publish_if_unchanged = function(path, candidate, files, expected, on_error)
					helpers.assert_eq(path, "owned"); helpers.assert_true(files == f.files)
					helpers.assert_eq(expected, { status = "ok", content = f.source })
					f.publications = f.publications + 1; f.source = candidate
					local native = f.receipt(expected, candidate, true, on_error)
					if f.acknowledge then f.receipts[native].settled = true; return true, nil, native end
					return false, "independent post-rename release refusal", native
				end,
			}
			local owner = Recovery.new({ files = f.files, writer = writer,
				capture = function() return f.epoch end, current = function(epoch) return f.epoch == epoch end })
			helpers.assert_true(owner.begin())
			helpers.assert_eq(owner.publish("owned", "split", f.files, { status = "ok", content = "legacy" }, f.on_error), false)
			helpers.assert_eq(owner.finish(), false)
			helpers.assert_true(owner.has_pending()); helpers.assert_eq(owner.begin(), false)
			helpers.assert_eq(owner.retry(), false); helpers.assert_eq(f.publications, 1)
			f.release = true
			f.retry_hook = function()
				-- The forward release succeeds; the subsequent inverse release refuses.
				if f.publications == 2 then f.release = false end
			end
			helpers.assert_eq(owner.retry(), false)
			helpers.assert_eq(f.source, "legacy"); helpers.assert_eq(f.publications, 2)
			helpers.assert_true(owner.has_pending()); helpers.assert_eq(owner.retry(), false)
			f.retry_hook = nil; f.release = true
			helpers.assert_true(owner.retry()); helpers.assert_eq(owner.has_pending(), false)
			f.acknowledge = true
			helpers.assert_true(owner.begin())
			helpers.assert_true(owner.publish("owned", "split", f.files, { status = "ok", content = "legacy" }, f.on_error))
			helpers.assert_true(owner.finish(true))
			helpers.assert_eq(f.publications, 3, "only a new acknowledged migration admits the split image")
		end)
	end)
end

return M
