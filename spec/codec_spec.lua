local helper = require("helper")

describe("Codec", function()
    local Codec
    before_each(function()
        Codec = helper.load().Codec
    end)

    local gather = {
        mapID = 1429, x = 0.41234, y = 0.6, kind = "mine", source = "gather",
        name = "Truesilver Deposit", objectID = 2047, items = {[7911] = 2, [7909] = 1}, money = 150
    }

    it("round-trips an observation", function()
        local messages = Codec.EncodeBatch("R", {gather})
        assert.are.equal(1, #messages)
        local flavor, entries = Codec.Decode(messages[1])
        assert.are.equal("R", flavor)
        local e = entries[1]
        assert.are.equal(1429, e.mapID)
        assert.are.equal(0.4123, e.x)
        assert.are.equal(0.6, e.y)
        assert.are.equal("mine", e.kind)
        assert.are.equal("gather", e.source)
        assert.are.equal("Truesilver Deposit", e.name)
        assert.are.equal(2047, e.objectID)
        assert.are.equal(2, e.items[7911])
        assert.are.equal(150, e.money)
    end)

    it("leaves optional fields out", function()
        local _, entries = Codec.Decode(Codec.EncodeBatch("F", {{mapID = 1, x = 0, y = 1, kind = "herb", source = "minimap"}})[1])
        local e = entries[1]
        assert.is_nil(e.name)
        assert.is_nil(e.objectID)
        assert.is_nil(e.items)
        assert.is_nil(e.money)
    end)

    it("splits batches at the message limit", function()
        local many = {}
        for i = 1, 20 do
            many[i] = gather
        end
        local messages = Codec.EncodeBatch("R", many)
        local total = 0
        for _, text in ipairs(messages) do
            assert.is_true(#text <= Codec.MAX_LENGTH)
            local _, entries = Codec.Decode(text)
            total = total + #entries
        end
        assert.are.equal(20, total)
        assert.is_true(#messages > 1)
    end)

    it("strips separator characters from names", function()
        local e = {mapID = 1, x = 0.5, y = 0.5, kind = "treasure", source = "vignette", name = "Bad^~;|Name"}
        local _, entries = Codec.Decode(Codec.EncodeBatch("R", {e})[1])
        assert.are.equal("BadName", entries[1].name)
    end)

    it("rejects other versions and junk", function()
        assert.is_nil(Codec.Decode("2;R;1^1^1^m^g^^^^"))
        assert.is_nil(Codec.Decode("hello"))
        assert.is_nil(Codec.Decode(nil))
        assert.is_nil(Codec.Decode(string.rep("x", 300)))
    end)

    it("drops malformed entries and keeps good ones", function()
        local good = Codec.EncodeEntry(gather)
        local text = "1;R;" .. table.concat({
            "1^20000^1^m^g^Big^^^",       -- x off the map
            "1^1^1^z^g^Kind^^^",          -- unknown kind
            "1^1^1^m^q^Src^^^",           -- unknown source
            "1^1^1^m^g^Item^^1:99999^",   -- quantity too large
            "-1^1^1^m^g^Neg^^^",          -- negative map
            "1^1^1^m^g",                  -- too few fields
            good
        }, "~")
        local _, entries = Codec.Decode(text)
        assert.are.equal(1, #entries)
        assert.are.equal("Truesilver Deposit", entries[1].name)
    end)
end)

describe("Codec catch-up messages", function()
    local Codec
    before_each(function()
        Codec = helper.load().Codec
    end)

    it("round-trips a query and an offer", function()
        local q = Codec.DecodeControl(Codec.EncodeQuery("R", 2395, 12))
        assert.are.same({flavor = "R", kind = "Q", mapID = 2395, count = 12}, q)
        local o = Codec.DecodeControl(Codec.EncodeOffer("R", 2395, "Kerfinor-Frostmourne", 40))
        assert.are.same({flavor = "R", kind = "O", mapID = 2395, count = 40, requester = "Kerfinor-Frostmourne"}, o)
    end)

    it("keeps control messages and node messages apart", function()
        assert.is_nil(Codec.Decode(Codec.EncodeQuery("R", 1, 0)))
        assert.is_nil(Codec.DecodeControl(Codec.EncodeBatch("R", {{mapID = 1, x = 0, y = 0, kind = "mine", source = "gather"}})[1]))
    end)

    it("rejects malformed control messages", function()
        assert.is_nil(Codec.DecodeControl("S2;R;Q;1;1"))
        assert.is_nil(Codec.DecodeControl("S1;R;Q;0;1"))
        assert.is_nil(Codec.DecodeControl("S1;R;Q;1;-1"))
        assert.is_nil(Codec.DecodeControl("S1;R;O;1;Bad|Name;1"))
        assert.is_nil(Codec.DecodeControl("S1;R;X;1;1"))
    end)

    it("carries caught-up nodes as sync entries", function()
        local e = {mapID = 2395, x = 0.5, y = 0.5, kind = "herb", source = "sync", name = "Tranquility Bloom", objectID = 516932}
        local _, entries = Codec.Decode(Codec.EncodeBatch("R", {e})[1])
        assert.are.equal("sync", entries[1].source)
        assert.are.equal(516932, entries[1].objectID)
    end)
end)

describe("Store.ExactNodes", function()
    it("leaves out nodes only known from hovers", function()
        local Store = helper.load().Store
        Store.Observe(1, 0.1, 0.1, "mine", "Tin Vein", "gather", 1000, 1000, 1000)
        Store.Observe(1, 0.9, 0.9, "mine", "Tin Vein", "minimap", 1000, 1000, 1000)
        assert.are.equal(1, #Store.ExactNodes(1))
        assert.are.equal(0, #Store.ExactNodes(2))
    end)
end)

describe("Store.Observe freshness", function()
    it("reports a new spawn as fresh and a repeat sighting as not", function()
        local Store = helper.load().Store
        local _, _, fresh1 = Store.Observe(1, 0.5, 0.5, "mine", "Tin Vein", "minimap", 1000, 1000, 1000)
        local _, _, fresh2 = Store.Observe(1, 0.5, 0.5, "mine", "Tin Vein", "minimap", 1000, 1000, 1030)
        local _, _, fresh3 = Store.Observe(1, 0.5, 0.5, "mine", "Tin Vein", "minimap", 1000, 1000, 2000)
        assert.is_true(fresh1)
        assert.is_false(fresh2)
        assert.is_true(fresh3)
    end)
end)
