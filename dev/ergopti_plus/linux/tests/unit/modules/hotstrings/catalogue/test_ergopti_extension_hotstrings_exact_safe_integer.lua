--- tests/unit/modules/hotstrings/catalogue/test_ergopti_extension_hotstrings_exact_safe_integer.lua

--- ==============================================================================
--- MODULE: Ergopti Extension Hotstrings (Linux)
--- DESCRIPTION:
--- SFB reduction, rolls and the magic key's repeat corrections moved from the
--- shared hotstrings folder into the Ergopti layout extension. These tests drive
--- the SHIPPED files through the real discovery, routing and loader: with the
--- Ergopti extension the driver ships, the three groups load under their
--- historical categories, sections and common tier, so every saved preference
--- still addresses them and the typed outputs are the ones the shared files
--- produced; without it, they are absent.
--- ==============================================================================

package.loaded["tests.support.modules.hotstrings.catalogue.ergopti_extension_hotstrings_fixture"] = nil
local Fixture = require("tests.support.modules.hotstrings.catalogue.ergopti_extension_hotstrings_fixture")
local helpers, with_exact_loader_ports =
	Fixture.helpers, Fixture.with_exact_loader_ports




helpers.describe("Exact safe-integer legacy filesystem serialization", function()
	for _, field in ipairs({ "ino", "dev" }) do
		local fixed = field
		helpers.it("(exact-safe-integer) refuses independently distinct adjacent safe " .. field .. " values", function()
			-- Both literals are representable on both ABIs; no expected key is
			-- obtained from the producer or from a numeric-to-text conversion.
			local left, right = 9007199254740990, 9007199254740991
			helpers.assert_true(left ~= right, "the two independently written native numeric facts are distinct")
			with_exact_loader_ports(function()
				package.loaded.lfs.attributes = function(path)
					local attrs = { mode = "file", dev = 11, ino = 100 }
					attrs[fixed] = path == "left" and left or right
					return attrs
				end
			end, function(Loader, _, state, owners)
				helpers.assert_eq(Loader.same_file("left", "right"), false,
					"distinct safe numeric identities must not collapse to the same legacy text key")
				helpers.assert_eq(#owners, 0)
				helpers.assert_eq(#state.opens, 0)
			end)
		end)
	end
	helpers.it("(exact-safe-integer) retains an independently equal high-safe source on both aliases", function()
		local reads = 0
		with_exact_loader_ports(function()
			package.loaded.lfs.attributes = function()
				reads = reads + 1
				return { mode = "file", dev = 9007199254740990, ino = 9007199254740991 }
			end
		end, function(Loader, _, state, owners)
			helpers.assert_true(Loader.same_file("left", "right"))
			helpers.assert_eq(reads, 4, "all original stable-source readbacks still execute")
			helpers.assert_eq(#owners, 0)
			helpers.assert_eq(#state.opens, 0)
		end)
	end)
end)

