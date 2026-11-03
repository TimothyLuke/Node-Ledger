local NL = NodeLedger
local Store = NL.Store

-- Rings on the world map: a standard map canvas data provider, so the map
-- handles zoom, panning and pin scaling. Pins are in WorldMap.xml.
NL.WorldMap = {}
local WM = NL.WorldMap

local TEMPLATE = "NodeLedgerWorldMapPinTemplate"
local REFRESH_DELAY = 0.5

-- Must exist before WorldMap.xml loads.
NodeLedgerWorldMapPinMixin = MapCanvasPinMixin and CreateFromMixins(MapCanvasPinMixin) or {}

function NodeLedgerWorldMapPinMixin:OnLoad()
    self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
    self:SetScalingLimits(1, 1.0, 1.4)
    self.Variant:SetVertexColor(NL.VariantColor[1], NL.VariantColor[2], NL.VariantColor[3])
end

function NodeLedgerWorldMapPinMixin:OnAcquired(node)
    self.node = node
    self:SetPosition(node.x, node.y)
    local color = NL.KindColors[node.kind]
    self.Ring:SetVertexColor(color[1], color[2], color[3])
    self.Variant:SetShown(Store.IsVariant(node))
end

function NodeLedgerWorldMapPinMixin:OnMouseEnter()
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    NL.Tooltip.AddNodeLines(GameTooltip, self.node, true)
    GameTooltip:Show()
end

function NodeLedgerWorldMapPinMixin:OnMouseLeave()
    GameTooltip:Hide()
end

local provider = MapCanvasDataProviderMixin and CreateFromMixins(MapCanvasDataProviderMixin)

if provider then
    function provider:RemoveAllData()
        self:GetMap():RemoveAllPinsByTemplate(TEMPLATE)
    end

    function provider:RefreshAllData()
        self:RemoveAllData()
        local options = Store.Options()
        if not options.worldMap then
            return
        end
        local nodes = Store.Nodes(self:GetMap():GetMapID())
        if not nodes then
            return
        end
        for _, node in pairs(nodes) do
            if options.show[node.kind] then
                self:GetMap():AcquirePin(TEMPLATE, node)
            end
        end
    end
end

function WM.Init()
    if provider and WorldMapFrame and WorldMapFrame.AddDataProvider then
        WorldMapFrame:AddDataProvider(provider)
        WM.ready = true
    end
end

function WM.Refresh()
    if WM.ready and WorldMapFrame:IsShown() then
        provider:RefreshAllData()
    end
end

local refreshQueued = false

--- The store changed: redraw the world map soon (the minimap redraws itself).
function NL.Changed()
    if refreshQueued then
        return
    end
    refreshQueued = true
    C_Timer.After(
        REFRESH_DELAY,
        function()
            refreshQueued = false
            WM.Refresh()
        end
    )
end
