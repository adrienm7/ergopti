--- tests/unit/lib/test_toml_publication_receipt_contract.lua

--- Protects ordinary cleanup callbacks and private opaque publication receipts.
local helpers = require("tests.helpers")
local function with_writer(body)
	helpers.with_fresh_modules({ "toml_codec.writer", "infra.logger" }, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		body(require("toml_codec.writer"))
	end)
end
local function source_adapter()
	return { read_with_status = function() return "original source", "ok" end }
end

helpers.describe("toml publication dual receipt boundary", function()
	helpers.it("preserves a generic two-argument publisher's exact cleanup callback on refusal", function()
		with_writer(function(writer)
			local adapter, writes, retries = source_adapter(), 0, 0
			local cleanup = function() retries = retries + 1; return true, nil, true end
			adapter.write = function(...)
				helpers.assert_eq(select("#", ...), 2)
				local path, content = ...
				helpers.assert_eq(path, "config"); helpers.assert_eq(content, "candidate")
				writes = writes + 1; return false, "release refused", cleanup
			end
			local committed, detail, receipt = writer.publish_if_unchanged("config", "candidate", adapter, { status = "ok", content = "original source" })
			helpers.assert_eq(committed, false); helpers.assert_eq(detail, "release refused")
			helpers.assert_eq(receipt, cleanup)
			local record = { publication_cleanup = receipt }
			local settled, _, published = writer.retry_publication_cleanup(record)
			helpers.assert_eq(settled, true); helpers.assert_eq(published, true)
			helpers.assert_eq(record.publication_cleanup, nil)
			helpers.assert_eq(writes, 1); helpers.assert_eq(retries, 1)
		end)
	end)

	helpers.it("preserves conditional ordinary cleanup with a nil diagnostic owner and exact refused retry", function()
		with_writer(function(writer)
			local adapter, admitted, retries = source_adapter(), false, 0
			local expected = { status = "ok", content = "original source" }
			local cleanup = function() retries = retries + 1; return admitted, "cleanup pending", false end
			adapter.write_if_unchanged = function(...)
				helpers.assert_eq(select("#", ...), 4)
				local _, _, source, on_error = ...
				helpers.assert_true(source == expected); helpers.assert_eq(on_error, nil)
				return false, "release refused", cleanup
			end
			local committed, _, receipt = writer.publish_if_unchanged("config", "candidate", adapter, expected)
			helpers.assert_eq(committed, false); helpers.assert_eq(receipt, cleanup)
			local record = { publication_cleanup = receipt }
			helpers.assert_eq(writer.retry_publication_cleanup(record), false)
			helpers.assert_eq(record.publication_cleanup, cleanup)
			admitted = true
			local settled, _, published = writer.retry_publication_cleanup(record)
			helpers.assert_eq(settled, true); helpers.assert_eq(published, false)
			helpers.assert_eq(record.publication_cleanup, nil); helpers.assert_eq(retries, 2)
		end)
	end)

	for _, committed in ipairs({ false, true }) do
		helpers.it("preserves the private opaque table and exact reporter with commit=" .. tostring(committed), function()
			with_writer(function(writer)
				local adapter, expected = source_adapter(), { status = "ok", content = "original source" }
				local reporter = function() end
				local receipt = setmetatable({}, { __newindex = function() error("immutable") end, __metatable = false })
				adapter.write_if_unchanged = function(...)
					helpers.assert_eq(select("#", ...), 4)
					local _, _, source, on_error = ...
					helpers.assert_true(source == expected); helpers.assert_true(on_error == reporter)
					return committed, nil, receipt
				end
				local written, _, returned = writer.publish_if_unchanged("config", "candidate", adapter, expected, reporter)
				helpers.assert_eq(written, committed); helpers.assert_true(returned == receipt)
				helpers.assert_eq(type(returned), "table")
			end)
		end)
	end

	helpers.it("does not fabricate a receipt when the conditional publisher throws", function()
		with_writer(function(writer)
			local adapter = source_adapter()
			adapter.write_if_unchanged = function() error("closed fixture refusal") end
			local committed, _, receipt = writer.publish_if_unchanged("config", "candidate", adapter, { status = "ok", content = "original source" }, function() end)
			helpers.assert_eq(committed, false); helpers.assert_nil(receipt)
		end)
	end)
end)
