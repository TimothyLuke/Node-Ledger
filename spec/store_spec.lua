local helper = require("helper")

describe("Store", function()
    local NL, Store, W, H
    before_each(function()
        NL = helper.load()
        Store = NL.Store
        W, H = helper.W, helper.H
    end)

    local function observe(x, y, kind, name, source, now)
        return Store.Observe(1, x, y, kind, name, source or "gather", W, H, now or 1000)
    end

    it("merges sightings within the merge radius into one node", function()
        local a, newA = observe(0.500, 0.500, "mine", "Copper Vein")
        local b, newB = observe(0.505, 0.500, "mine", "Copper Vein", "gather", 2000) -- 5 yards
        assert.is_true(newA)
        assert.is_false(newB)
        assert.are.equal(a, b)
        assert.are.equal(2, a.gathered)
    end)

    it("keeps different kinds and distant nodes apart", function()
        local mine = observe(0.5, 0.5, "mine", "Copper Vein")
        local herb = observe(0.5, 0.5, "herb", "Peacebloom")
        local far = observe(0.6, 0.5, "mine", "Copper Vein") -- 100 yards
        assert.are_not.equal(mine, herb)
        assert.are_not.equal(mine, far)
    end)

    it("counts one spawn once whether hovered then gathered", function()
        local node = observe(0.5, 0.5, "mine", "Mithril Deposit", "minimap", 1000)
        observe(0.5, 0.5, "mine", "Mithril Deposit", "minimap", 1010)
        observe(0.5, 0.5, "mine", "Mithril Deposit", "gather", 1030)
        assert.are.equal(1, node.names["Mithril Deposit"])
        assert.are.equal(1, node.sightings)
        assert.are.equal(1, node.gathered)
    end)

    it("tracks variant spawns at one point", function()
        local node = observe(0.5, 0.5, "mine", "Mithril Deposit", "gather", 1000)
        observe(0.5, 0.5, "mine", "Mithril Deposit", "gather", 5000)
        observe(0.5, 0.5, "mine", "Truesilver Deposit", "gather", 9000)
        assert.is_true(Store.IsVariant(node))
        local names = Store.SortedNames(node)
        assert.are.equal("Mithril Deposit", names[1].name)
        assert.are.equal(2, names[1].count)
        assert.are.equal("Truesilver Deposit", names[2].name)
    end)

    it("is not a variant with one spawn name", function()
        local node = observe(0.5, 0.5, "herb", "Peacebloom")
        assert.is_false(Store.IsVariant(node))
    end)

    it("pulls the position toward heavier observations", function()
        local node = observe(0.500, 0.5, "mine", "Tin Vein", "minimap", 1000)
        observe(0.508, 0.5, "mine", "Tin Vein", "gather", 2000)
        assert.is_true(node.x > 0.505 and node.x < 0.508)
    end)

    it("averages hauls per node and across every node of a name", function()
        local a = observe(0.2, 0.2, "mine", "Copper Vein")
        local b = observe(0.8, 0.8, "mine", "Copper Vein")
        Store.AddHaul(a, "Copper Vein", {[2770] = 2, [2835] = 1})
        Store.AddHaul(a, "Copper Vein", {[2770] = 4})
        Store.AddHaul(b, "Copper Vein", {[2770] = 3})
        Store.AddMoney(a, "Copper Vein", 50)

        local here = Store.HaulSummary(a.hauls["Copper Vein"])
        assert.are.equal(2770, here[1].itemID)
        assert.are.equal(3, here[1].avg)
        assert.are.equal(1, here[1].chance)
        assert.are.equal(0.5, here[2].chance)

        local all = Store.NameHaul("Copper Vein")
        assert.are.equal(3, all.visits)
        assert.are.equal(3, all.items[2770].qty / all.visits)
        assert.are.equal(50, all.money)
    end)

    it("learns names and object IDs", function()
        Store.Observe(1, 0.5, 0.5, "herb", "Glowing Sporecap", "gather", W, H, 1000, 12345)
        assert.are.equal("herb", Store.NameKind("Glowing Sporecap"))
        assert.are.equal("herb", Store.ObjectKind(12345))
    end)

    it("removes nodes and counts what's left", function()
        local node = observe(0.5, 0.5, "mine", "Copper Vein")
        observe(0.1, 0.1, "herb", "Peacebloom")
        Store.Remove(1, node.id)
        local total, here = Store.Counts(1)
        assert.is_nil(total.mine)
        assert.are.equal(1, here.herb)
    end)
end)

describe("Names", function()
    local Names, Store
    before_each(function()
        local NL = helper.load()
        Names, Store = NL.Names, NL.Store
    end)

    it("classifies by seed, pattern and stripped prefix", function()
        assert.are.equal("herb", Names.KindOf("Peacebloom"))
        assert.are.equal("mine", Names.KindOf("Rich Thorium Vein"))
        assert.are.equal("mine", Names.KindOf("Truesilver Deposit"))
        assert.are.equal("herb", Names.KindOf("Lush Mycobloom"))
        assert.are.equal("fish", Names.KindOf("Oily Blackmouth School"))
        assert.are.equal("fish", Names.KindOf("School of Tastyfish"))
        assert.are.equal("treasure", Names.KindOf("Battered Chest"))
        assert.is_nil(Names.KindOf("Hogger"))
        assert.is_nil(Names.KindOf(nil))
    end)

    it("prefers what it has learned", function()
        Store.LearnName("Blessing Blossom", "treasure")
        assert.are.equal("treasure", Names.KindOf("Blessing Blossom"))
    end)

    it("knows the base gather spells", function()
        assert.are.equal("herb", Names.SpellKind(2366))
        assert.are.equal("mine", Names.SpellKind(2575))
        assert.are.equal("open", Names.SpellKind(3365))
        assert.is_nil(Names.SpellKind(133))
    end)
end)
