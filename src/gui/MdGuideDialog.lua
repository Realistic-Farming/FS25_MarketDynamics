-- =========================================================
-- Market Field Guide - Field Guide
-- =========================================================
-- BUILD 19:15 (George CLOSED DESIGN 18:55 item 5): every Realistic Farming Esc page gets its own
-- guide, in its own mod, opened from the shared Help footer through this guest's onOpenHelp. The
-- chrome is SoilGuideDialog's so all of them read as one family; only the words differ.
-- Rows are { t = "H" | "B" | "S" | "COL", v = "text" }: header, body, spacer, column break.
-- =========================================================

---@class MdGuideDialog
MdGuideDialog = MdGuideDialog or {}
local MdGuideDialog_mt = Class(MdGuideDialog, ScreenElement)

local GUIDE_MOD_DIR = (MarketDynamicsModDirectory or g_currentModDirectory)

MdGuideDialog.INSTANCE = nil
MdGuideDialog.GUI_NAME = "MdGuideDialog"

MdGuideDialog.SUBTITLES = {
    "Overview - what the mod does and where to find it",
    "How Prices Move - the price engine and the graph",
    "Market Events - what can fire and what it does",
    "Futures Contracts - opening, delivering, cancelling",
    "Settings and FAQ - every setting and common fixes",
}

MdGuideDialog.PAGE1 = {
    { t="H", v="WHAT THIS MOD DOES" },
    { t="B", v="Crop prices no longer sit still. Every good" },
    { t="B", v="the game buys gets a live price that drifts" },
    { t="B", v="through the day and shifts again each day." },
    { t="B", v="World events can push whole groups of goods" },
    { t="B", v="up or down for as long as they last." },
    { t="B", v="You are paid the live price when you sell at" },
    { t="B", v="a selling station." },
    { t="B", v="Futures contracts let you lock today's price" },
    { t="B", v="and deliver the crop later." },
    { t="S", v=" " },
    { t="H", v="FINDING THE PAGE" },
    { t="B", v="Open the pause menu and choose the Realistic" },
    { t="B", v="Farming tab." },
    { t="B", v="At the top of that page, use the module" },
    { t="B", v="picker to select Market Dynamics." },
    { t="B", v="A second picker underneath gives three" },
    { t="B", v="pages: Prices, Events and Contracts." },
    { t="S", v=" " },
    { t="COL", v="" },
    { t="H", v="THE TABLE AT THE TOP" },
    { t="B", v="All three pages share one table of tracked" },
    { t="B", v="goods, with Crop, Price and Change columns." },
    { t="B", v="Click a row to pick that good. Your pick" },
    { t="B", v="drives the graph and the new contract card." },
    { t="B", v="The page refreshes itself every couple of" },
    { t="B", v="seconds, so the numbers stay current." },
    { t="S", v=" " },
    { t="H", v="WHAT EACH PAGE IS FOR" },
    { t="B", v="Prices: the good you picked, its price and" },
    { t="B", v="a trend graph under the table." },
    { t="B", v="Events: what is hitting the market now." },
    { t="B", v="Contracts: your open deals, and a card for" },
    { t="B", v="opening a new one." },
    { t="S", v=" " },
    { t="H", v="ANOTHER WAY IN" },
    { t="B", v="A larger Market screen opens on its own key," },
    { t="B", v="by default Right Shift and 5. It shows the" },
    { t="B", v="same three tabs with more detail and a New" },
    { t="B", v="Contract button. The key can be rebound" },
    { t="B", v="under Options, Controls." },
}

MdGuideDialog.PAGE2 = {
    { t="H", v="HOW A PRICE IS BUILT" },
    { t="B", v="Each good starts from the price the game" },
    { t="B", v="itself would pay. That base is refreshed once" },
    { t="B", v="a day, so seasonal swings still count." },
    { t="B", v="On top of the base sits a drift factor that" },
    { t="B", v="wanders up and down." },
    { t="B", v="Anything an event is doing multiplies on top" },
    { t="B", v="of that." },
    { t="B", v="The result never falls below half the base" },
    { t="B", v="price and never rises above double it." },
    { t="S", v=" " },
    { t="H", v="HOW OFTEN IT MOVES" },
    { t="B", v="A small nudge lands every in-game minute." },
    { t="B", v="A larger shift lands once per in-game day," },
    { t="B", v="and that day's price is kept for the graph." },
    { t="B", v="Drift is always pulled gently back toward" },
    { t="B", v="the base, so no run lasts forever." },
    { t="S", v=" " },
    { t="COL", v="" },
    { t="H", v="READING THE TABLE" },
    { t="B", v="Prices are written per 1,000 litres." },
    { t="B", v="Animals are priced per head instead." },
    { t="B", v="Change is the gap between the live price and" },
    { t="B", v="the base price, as a percentage." },
    { t="B", v="Under the table the Prices page names your" },
    { t="B", v="picked good, its price and change, and adds" },
    { t="B", v="a plain reading such as near base, softly up," },
    { t="B", v="up sharply or soft against base." },
    { t="S", v=" " },
    { t="H", v="THE PRICE TREND GRAPH" },
    { t="B", v="The graph draws under the table on the" },
    { t="B", v="Prices page, for the good you picked." },
    { t="B", v="With nothing picked it asks you to pick one." },
    { t="B", v="A good with too little history says so, and" },
    { t="B", v="the line appears as prices build up across" },
    { t="B", v="in-game days." },
    { t="B", v="The line is fed by samples taken while you" },
    { t="B", v="play, plus the daily prices the mod keeps." },
}

MdGuideDialog.PAGE3 = {
    { t="H", v="WHAT A MARKET EVENT IS" },
    { t="B", v="Now and then the market throws an event." },
    { t="B", v="While it runs it pushes the price of the" },
    { t="B", v="goods it touches up or down." },
    { t="B", v="Events start on their own, run for a while," },
    { t="B", v="then expire by themselves." },
    { t="B", v="The mod rolls for a new event on a regular" },
    { t="B", v="check, and each event has a cooling-off gap" },
    { t="B", v="so the same one cannot fire back to back." },
    { t="S", v=" " },
    { t="H", v="THE EVENTS THAT CAN FIRE" },
    { t="B", v="Regional Drought" },
    { t="B", v="Bumper Harvest" },
    { t="B", v="Trade Disruption" },
    { t="B", v="Geopolitical Crisis" },
    { t="B", v="Biofuel Initiative" },
    { t="B", v="Livestock Feed Boom" },
    { t="B", v="Root Crop Blight" },
    { t="B", v="Cold Snap" },
    { t="B", v="Financial Panic" },
    { t="B", v="Protein Premium Surge" },
    { t="S", v=" " },
    { t="COL", v="" },
    { t="H", v="THE EVENTS PAGE" },
    { t="B", v="The left card lists what is running now," },
    { t="B", v="under Event, Intensity and Time left." },
    { t="B", v="Intensity reads Mild, Moderate or Severe." },
    { t="B", v="Time left counts down to the end of it." },
    { t="B", v="Up to eight events are listed. If more are" },
    { t="B", v="running, a line says how many are hidden." },
    { t="B", v="When the market is calm the card simply says" },
    { t="B", v="there are no active market events." },
    { t="S", v=" " },
    { t="H", v="THE EVENT SETTINGS CARD" },
    { t="B", v="The right card is a read-only summary:" },
    { t="B", v="whether events are switched on, how often" },
    { t="B", v="they are set to happen, how many events are" },
    { t="B", v="enabled out of the total, and which ones are" },
    { t="B", v="running right now." },
    { t="B", v="The Event settings button opens the full" },
    { t="B", v="dialog, with the master switch, frequency," },
    { t="B", v="per-event rules and the goods they hit." },
    { t="B", v="Only the server host or an admin can open" },
    { t="B", v="it. Everyone else sees a host only note." },
}

MdGuideDialog.PAGE4 = {
    { t="H", v="WHAT A FUTURES CONTRACT IS" },
    { t="B", v="You promise a number of litres of one good" },
    { t="B", v="by a deadline, at the price locked when you" },
    { t="B", v="sign." },
    { t="B", v="You are still paid the live market price at" },
    { t="B", v="the station as you deliver. The contract" },
    { t="B", v="settles the difference at the end, so the" },
    { t="B", v="litres you promised are worth exactly the" },
    { t="B", v="locked price, no more and no less." },
    { t="S", v=" " },
    { t="H", v="OPENING ONE" },
    { t="B", v="Go to the Contracts page and pick a good in" },
    { t="B", v="the table at the top first." },
    { t="B", v="The New contract card on the right then" },
    { t="B", v="shows that good and the price it would lock." },
    { t="B", v="Choose a quantity: 500, 1,000, 5,000," },
    { t="B", v="10,000, 25,000 or 50,000 litres." },
    { t="B", v="Choose a delivery window: 30, 60, 90 or" },
    { t="B", v="120 days." },
    { t="B", v="Press Confirm contract. The deal appears on" },
    { t="B", v="the left once the server accepts it." },
    { t="S", v=" " },
    { t="COL", v="" },
    { t="H", v="YOUR OPEN DEALS" },
    { t="B", v="The left card lists up to five deals, with" },
    { t="B", v="Crop, Quantity, Locked price and Status." },
    { t="B", v="Status reads Active, At risk, Fulfilled or" },
    { t="B", v="Failed. At risk means the deadline is close" },
    { t="B", v="and less than half has been delivered." },
    { t="B", v="To deliver, just sell that good at any" },
    { t="B", v="selling station. Litres count against your" },
    { t="B", v="matching deals on their own." },
    { t="S", v=" " },
    { t="H", v="CANCELLING A DEAL" },
    { t="B", v="Click a deal in the list to pick it, then" },
    { t="B", v="press Cancel deal." },
    { t="B", v="Cancelling defaults the deal there and then." },
    { t="B", v="What you already delivered settles at the" },
    { t="B", v="locked price, and the leave-early fee is" },
    { t="B", v="charged on every litre you did not deliver." },
    { t="B", v="It can end as a charge rather than a payment," },
    { t="B", v="so only cancel when you mean it." },
}

MdGuideDialog.PAGE5 = {
    { t="H", v="OPENING THE SETTINGS PANEL" },
    { t="B", v="The settings panel has its own Controls" },
    { t="B", v="action, by default Right Shift and the slash" },
    { t="B", v="key. Rebind it under Options, Controls." },
    { t="B", v="It will not open while another menu or" },
    { t="B", v="dialog is already on screen." },
    { t="B", v="The panel opens on two cards, Market Engines" },
    { t="B", v="and Simulation. Click a card, then click a" },
    { t="B", v="value to change it." },
    { t="B", v="A bar at the bottom says whether you count" },
    { t="B", v="as an admin, and single or multiplayer." },
    { t="S", v=" " },
    { t="H", v="MARKET ENGINES" },
    { t="B", v="Dynamic Prices turns all price movement on" },
    { t="B", v="or off, giving the game's own prices back." },
    { t="B", v="Real Days Delivery makes contract deadlines" },
    { t="B", v="follow real time instead of in-game days." },
    { t="B", v="Default Penalty sets the fee charged on" },
    { t="B", v="undelivered litres: 8, 15 or 25 percent." },
    { t="S", v=" " },
    { t="COL", v="" },
    { t="H", v="SIMULATION" },
    { t="B", v="World Events allows or blocks events." },
    { t="B", v="Prices still drift when events are off." },
    { t="B", v="Event Frequency sets Rare, Normal or Frequent." },
    { t="B", v="Event Notifications announces a new event." },
    { t="B", v="Compact Event Banner turns that into a small" },
    { t="B", v="corner banner instead of a pop-up." },
    { t="B", v="Contract HUD shows a progress tracker for" },
    { t="B", v="active contracts. Drag it with the left" },
    { t="B", v="mouse button; the wheel resizes it." },
    { t="B", v="Debug Mode and Experimental Systems are for" },
    { t="B", v="testing. Leave them off for normal play." },
    { t="S", v=" " },
    { t="H", v="COMMON QUESTIONS" },
    { t="B", v="Prices look frozen. Check Dynamic Prices is" },
    { t="B", v="on, then give it an in-game minute." },
    { t="B", v="The graph is empty. Pick a good, then let a" },
    { t="B", v="few in-game days pass." },
    { t="B", v="Event settings are host or admin only." },
    { t="B", v="The new contract card is grey. Either no" },
    { t="B", v="good is picked, or the Futures Mission" },
    { t="B", v="add-on is installed and owns contracts." },
    { t="B", v="Only crop sold after you sign counts." },
}

MdGuideDialog.PAGE_CONTENT = { MdGuideDialog.PAGE1, MdGuideDialog.PAGE2, MdGuideDialog.PAGE3, MdGuideDialog.PAGE4, MdGuideDialog.PAGE5 }

-- -- Constructor ------------------------------------------

function MdGuideDialog.new(target, customMt)
    local self = ScreenElement.new(target, customMt or MdGuideDialog_mt)
    self._contentLineEls = {}
    self._currentPage = 1
    return self
end

--- Loads the dialog into g_gui once. Safe to call twice, and safe to call when some other path has
--- already registered the same name.
function MdGuideDialog.register(modDirectory)
    if g_gui == nil then return end
    if g_gui.guis ~= nil and g_gui.guis[MdGuideDialog.GUI_NAME] ~= nil then return end
    if modDirectory ~= nil then GUIDE_MOD_DIR = modDirectory end
    if GUIDE_MOD_DIR == nil then return end
    MdGuideDialog.INSTANCE = MdGuideDialog.new()
    local ok, err = pcall(function()
        g_gui:loadGui(GUIDE_MOD_DIR .. "xml/gui/MdGuideDialog.xml", MdGuideDialog.GUI_NAME, MdGuideDialog.INSTANCE)
    end)
    if not ok then
        print("[MDM] MdGuideDialog: loadGui failed: " .. tostring(err))
        MdGuideDialog.INSTANCE = nil
    end
end

function MdGuideDialog.show()
    if g_gui == nil then return end
    local loaded = g_gui.guis ~= nil and g_gui.guis[MdGuideDialog.GUI_NAME] ~= nil
    if not loaded then
        MdGuideDialog.register(GUIDE_MOD_DIR)
        loaded = g_gui.guis ~= nil and g_gui.guis[MdGuideDialog.GUI_NAME] ~= nil
    end
    if not loaded then return end
    g_gui:showDialog(MdGuideDialog.GUI_NAME)
end

-- -- Lifecycle --------------------------------------------

function MdGuideDialog:onGuiSetupFinished()
    MdGuideDialog:superClass().onGuiSetupFinished(self)
    self._elCol1 = self:getDescendantById("mdGuide_col1")
    self._elCol2 = self:getDescendantById("mdGuide_col2")
    self._elSubtitle = self:getDescendantById("mdGuide_subtitle")
end

function MdGuideDialog:onOpen()
    MdGuideDialog:superClass().onOpen(self)
    self._currentPage = 1
    self:_selectPage(1)
end

function MdGuideDialog:onClose()
    MdGuideDialog:superClass().onClose(self)
    self:_clearContent()
    self._currentPage = 1
end

-- -- Tabs -------------------------------------------------

function MdGuideDialog:onClickTab1() self:_selectPage(1) end
function MdGuideDialog:onClickTab2() self:_selectPage(2) end
function MdGuideDialog:onClickTab3() self:_selectPage(3) end
function MdGuideDialog:onClickTab4() self:_selectPage(4) end
function MdGuideDialog:onClickTab5() self:_selectPage(5) end

function MdGuideDialog:_selectPage(pageNum)
    if self._currentPage == pageNum and #self._contentLineEls > 0 then return end
    self:_clearContent()
    self._currentPage = pageNum
    if self._elSubtitle ~= nil then
        self._elSubtitle:setText(MdGuideDialog.SUBTITLES[pageNum] or "")
    end
    self:_buildContent(pageNum)
end

-- -- Content ----------------------------------------------

function MdGuideDialog:_buildContent(pageNum)
    local profileH = g_gui:getProfile("mdGuide_colHeader")
    local profileB = g_gui:getProfile("mdGuide_colBody")
    local profileS = g_gui:getProfile("mdGuide_colSpacer")
    if not profileH or not profileB then
        print("[MDM] MdGuideDialog: column profiles not found")
        return
    end
    local content = MdGuideDialog.PAGE_CONTENT[pageNum]
    if content == nil then return end
    local currentBox = self._elCol1
    for _, row in ipairs(content) do
        if row.t == "COL" then
            if self._elCol1 ~= nil then self._elCol1:invalidateLayout() end
            currentBox = self._elCol2
        elseif currentBox ~= nil then
            local profile = (row.t == "H") and profileH
                         or (row.t == "S") and profileS
                         or profileB
            if profile ~= nil then
                local el = TextElement.new()
                el:loadProfile(profile, true)
                el:setText(row.v or "")
                currentBox:addElement(el)
                el:onGuiSetupFinished()
                table.insert(self._contentLineEls, { box = currentBox, el = el })
            end
        end
    end
    if self._elCol2 ~= nil then self._elCol2:invalidateLayout() end
end

function MdGuideDialog:_clearContent()
    for _, entry in ipairs(self._contentLineEls or {}) do
        if entry.box ~= nil then
            entry.box:removeElement(entry.el)
        end
    end
    self._contentLineEls = {}
    if self._elCol1 ~= nil then self._elCol1:invalidateLayout() end
    if self._elCol2 ~= nil then self._elCol2:invalidateLayout() end
end

-- -- Button -----------------------------------------------

function MdGuideDialog:onClickClose()
    g_gui:closeDialogByName(MdGuideDialog.GUI_NAME)
end
