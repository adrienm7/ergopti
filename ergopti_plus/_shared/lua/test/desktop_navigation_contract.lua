--- _shared/lua/test/desktop_navigation_contract.lua

--- Replays the shared desktop-navigation corpus against the pure index maths.
return function(helpers, json, shared_root)
	local Navigation = require("desktop_navigation")

	local function read_corpus()
		local file = assert(io.open(shared_root .. "/tests/corpus/desktop_navigation/vectors.json", "rb"))
		local text = file:read("*a")
		file:close()
		return json.decode(text)
	end

	helpers.describe("desktop navigation: the shared index maths", function()
		helpers.it("lands every vector on its target (desktop-navigation-vectors)", function()
			local corpus = read_corpus()
			helpers.assert_true(#corpus.vectors >= 20, "the corpus must hold its vectors")
			local edges = 0
			for _, vector in ipairs(corpus.vectors) do
				local target = Navigation.target(vector.index, vector.count, vector.direction, vector.wrap)
				helpers.assert_eq(target, vector.target, vector.id)
				helpers.assert_eq(Navigation.steps(vector.index, vector.count, vector.direction, vector.wrap),
					vector.target - vector.index, vector.id .. " steps")
				if math.abs(vector.target - vector.index) > 1 then edges = edges + 1 end
			end
			helpers.assert_true(edges >= 4, "the corpus must cross an edge in both directions")
		end)

		helpers.it("wraps from the last desktop to the first and stays without wrapping", function()
			helpers.assert_eq(Navigation.target(3, 4, Navigation.NEXT, true), 0)
			helpers.assert_eq(Navigation.target(3, 4, Navigation.NEXT, false), 3)
			helpers.assert_eq(Navigation.target(0, 4, Navigation.PREVIOUS, true), 3)
			helpers.assert_eq(Navigation.target(0, 4, Navigation.PREVIOUS, false), 0)
		end)

		helpers.it("refuses every invalid read instead of guessing a position", function()
			local corpus = read_corpus()
			helpers.assert_true(#corpus.invalid >= 7, "the corpus must hold its invalid inputs")
			for _, vector in ipairs(corpus.invalid) do
				local ok, err = pcall(Navigation.target, vector.index, vector.count, vector.direction, vector.wrap)
				helpers.assert_eq(ok, false, vector.id .. " must be refused")
				helpers.assert_contains(tostring(err), "desktop_navigation:", vector.id .. " must be refused by the rule")
			end
		end)
	end)
end
