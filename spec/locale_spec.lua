-- Every L["..."] in Core/ must be in the enUS master list.
describe("Localization", function()
    it("lists every phrase the code uses", function()
        local listed = {}
        for key in io.open("Localization/enUS.lua"):read("*a"):gmatch('L%["(.-)"%] = true') do
            listed[key] = true
        end
        local missing = {}
        for file in io.popen("ls Core/*.lua"):lines() do
            for key in io.open(file):read("*a"):gmatch('L%["(.-)"%]') do
                if not listed[key] then
                    missing[#missing + 1] = file .. ": " .. key
                end
            end
        end
        assert.are.same({}, missing)
    end)
end)
