--- tests/hardware/run_crypto_receipts.lua
--- Drives production Crypto with the real OpenSSL native binding on Linux. The
--- shared independent byte vectors include NUL, UTF-8 and shell metacharacters.
--- No primitive is mocked; no keyboard or graphical session is required.
local Crypto = require("adapters.crypto")
local checks, failures = 0, 0
for _, row in ipairs(require("tests.support.crypto_vectors")) do
	checks = checks + 1
	collectgarbage("collect") -- The native provider must retain its library ownership.
	local ok, value = pcall(Crypto.sha256, row.input)
	if ok and value == row.sha256 then
		print("PASS native SHA-256 " .. row.id)
	else
		failures = failures + 1
		io.stderr:write("FAIL native SHA-256 " .. row.id .. ": " .. tostring(value) .. "\n")
	end
end
print(string.format("Native crypto receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
