-- Forever Item Tracker PLUS: what each of your characters holds, and the last auction house price,
-- added to item and gold tooltips. Nothing else.

local ADDON = ...
local PREFIX = "|cff33ff99Forever Item Tracker PLUS|r: "
local STALE = 12 * 3600        -- scan age shown in red after this many seconds
local MIN_RESCAN = 60 * 60     -- automatic scans at most once an hour
local SERVER_COOLDOWN = 15 * 60 -- the server ignores full scans closer together than this

local DB, me, realm, priceKey
local bankOpen, ahOpen, scanning, awaiting, ticker
local merchantOpen, selling

local LOCS = { "bags", "bank", "mail", "equip" }
-- Flat white icons, tinted here: |Tpath:h:w:x:y:texW:texH:left:right:top:bottom:r:g:b|t
local function Tex(file, r, g, b)
    return string.format("|TInterface\\AddOns\\%s\\media\\%s:14:14:0:0:64:64:0:64:0:64:%d:%d:%d|t",
        ADDON, file, r, g, b)
end
local ICON = {
    bags  = Tex("bag",   230, 200, 140),
    bank  = Tex("bank",  200, 200, 210),
    mail  = Tex("mail",  150, 190, 230),
    equip = Tex("equip", 160, 210, 150),
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function Msg(fmt, ...) print(PREFIX .. string.format(fmt, ...)) end

local Coin = GetCoinTextureString
    or (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString)
    or function(c)
        return string.format("%dg %ds %dc", math.floor(c / 10000), math.floor(c % 10000 / 100), c % 100)
    end

-- Forever moved some globals into C_ namespaces; use whichever exists.
local ItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local function LinkID(link) return link and tonumber(link:match("item:(%d+)")) end

local function Ago(s)
    if s < 60 then return "just now" end
    if s < 3600 then return string.format("%dm ago", math.floor(s / 60)) end
    if s < 86400 then return string.format("%dh %dm ago", math.floor(s / 3600), math.floor(s % 3600 / 60)) end
    return string.format("%dd %dh ago", math.floor(s / 86400), math.floor(s % 86400 / 3600))
end

local function Me()
    local c = DB.chars[me]
    if not c then
        c = { bags = {}, bank = {}, mail = {}, equip = {}, gold = 0 }
        DB.chars[me] = c
    end
    return c
end

local function ColoredName(c)
    local name = c.name or "?"
    local col = RAID_CLASS_COLORS and c.class and RAID_CLASS_COLORS[c.class]
    if col then
        name = string.format("|cff%02x%02x%02x%s|r", col.r * 255, col.g * 255, col.b * 255, name)
    end
    if c.realm ~= realm then name = name .. "|cff808080-" .. (c.realm or "?") .. "|r" end
    return name
end

local function SortedChars()
    local list = {}
    for k in pairs(DB.chars) do list[#list + 1] = k end
    table.sort(list, function(a, b)
        if a == me then return true elseif b == me then return false end
        return a < b
    end)
    return list
end

---------------------------------------------------------------------------
-- Inventory scanning
---------------------------------------------------------------------------
local CC = C_Container
local NumSlots = (CC and CC.GetContainerNumSlots) or GetContainerNumSlots

local function SlotItem(bag, slot)
    if CC and CC.GetContainerItemInfo then
        local info = CC.GetContainerItemInfo(bag, slot)
        if info then return info.itemID or LinkID(info.hyperlink), info.stackCount end
    else
        local _, count, _, _, _, _, link, _, _, id = GetContainerItemInfo(bag, slot)
        if link then return id or LinkID(link), count end
    end
end

-- Build the container lists from whatever the client defines, so extra slots
-- such as profession bags (Herb Pouch etc.) are included, not just bags 1-4.
local BAGS, BANK = {}, {}
do
    local seen = {}
    local function add(list, id)
        if type(id) == "number" and not seen[id] then
            seen[id] = true
            list[#list + 1] = id
        end
    end
    if Enum and Enum.BagIndex then
        for name, id in pairs(Enum.BagIndex) do
            add(name:lower():find("bank") and BANK or BAGS, id)
        end
    end
    local equipped = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
    for i = 0, equipped do add(BAGS, i) end
    add(BAGS, KEYRING_CONTAINER)
    add(BANK, BANK_CONTAINER or -1)
    for i = equipped + 1, equipped + (NUM_BANKBAGSLOTS or 6) do add(BANK, i) end
    table.sort(BAGS)
    table.sort(BANK)
end

local BagInvID = (CC and CC.ContainerIDToInventoryID) or ContainerIDToInventoryID

local function Count(bags)
    local t = {}
    for _, bag in ipairs(bags) do
        -- the bag item itself, sitting in a bag slot (e.g. a Herb Pouch)
        if bag > 0 and BagInvID then
            local ok, inv = pcall(BagInvID, bag)
            local id = ok and inv and GetInventoryItemID("player", inv)
            if id then t[id] = (t[id] or 0) + 1 end
        end
        local ok, slots = pcall(NumSlots, bag)
        for slot = 1, (ok and slots or 0) do
            local id, n = SlotItem(bag, slot)
            if id then t[id] = (t[id] or 0) + (n or 1) end
        end
    end
    return t
end

local function ScanBags()
    local c = Me()
    c.bags = Count(BAGS)
    if bankOpen then c.bank = Count(BANK) end
end

local pending
local function QueueBags()
    if pending then return end
    pending = true
    C_Timer.After(0.3, function() pending = false; ScanBags() end)
end

---------------------------------------------------------------------------
-- Bank: move items that already exist on the other side
---------------------------------------------------------------------------
local UseItem = (CC and CC.UseContainerItem) or UseContainerItem
local function SlotLocked(bag, slot)
    if CC and CC.GetContainerItemInfo then
        local info = CC.GetContainerItemInfo(bag, slot)
        return info and info.isLocked
    end
    return select(3, GetContainerItemInfo(bag, slot))
end

-- Item IDs in a set of containers (contents only, not the bags themselves).
local function IDsIn(bags)
    local t = {}
    for _, bag in ipairs(bags) do
        local ok, slots = pcall(NumSlots, bag)
        for slot = 1, (ok and slots or 0) do
            local id = SlotItem(bag, slot)
            if id then t[id] = true end
        end
    end
    return t
end

local moving
local bankButtons
local function SetBankButtonsEnabled(on)
    if not bankButtons then return end
    for _, b in ipairs(bankButtons) do b:SetEnabled(on) end
end

-- Move items from the `from` containers to the other side. With onlyID, every
-- stack of that one item moves; otherwise every item whose ID the `to` side
-- already holds. The game moves an item to the other side when you "use" it
-- while the bank is open; one stack every 0.1s keeps the server from
-- rejecting moves.
local function MoveItems(from, to, verb, onlyID)
    if not bankOpen then Msg("open your bank first.") return end
    if moving then Msg("already moving items.") return end
    local want = not onlyID and IDsIn(to)
    local queue = {}
    for _, bag in ipairs(from) do
        if bag ~= KEYRING_CONTAINER then
            local ok, slots = pcall(NumSlots, bag)
            for slot = 1, (ok and slots or 0) do
                local id = SlotItem(bag, slot)
                if id and (id == onlyID or (want and want[id])) then
                    queue[#queue + 1] = { bag, slot, id }
                end
            end
        end
    end
    if #queue == 0 then
        if not onlyID then Msg("nothing to %s.", verb) end
        return
    end

    moving = true
    SetBankButtonsEnabled(false)
    local i = 1
    local ticker
    local function finish()
        if ticker then ticker:Cancel() end
        -- give the last moves a moment to land, then count what stayed behind
        C_Timer.After(0.6, function()
            moving = false
            SetBankButtonsEnabled(true)
            local stuck = 0
            for _, q in ipairs(queue) do
                if SlotItem(q[1], q[2]) == q[3] then stuck = stuck + 1 end
            end
            local moved = #queue - stuck
            local what = string.format("%d stack%s", moved, moved == 1 and "" or "s")
            if onlyID then
                local link = ItemInfo and select(2, ItemInfo(onlyID))
                if link then what = what .. " of " .. link end
            end
            Msg("%s %s%s", verb == "deposit" and "deposited" or "withdrew", what,
                stuck > 0 and string.format("; %d didn't fit.", stuck) or ".")
            QueueBags()
        end)
    end
    ticker = C_Timer.NewTicker(0.1, function()
        if not bankOpen then finish() return end
        local q = queue[i]
        if not q then finish() return end
        local bag, slot, id = q[1], q[2], q[3]
        if SlotLocked(bag, slot) then return end -- try this slot again next tick
        if SlotItem(bag, slot) == id then UseItem(bag, slot) end
        i = i + 1
    end)
end

-- Ctrl+click an item while the bank is open: every stack of it moves to the
-- other side. Bag and bank item buttons both route modified clicks through
-- HandleModifiedItemClick, so one hook covers both.
local BANKSET = {}
for _, id in ipairs(BANK) do BANKSET[id] = true end

local function ClickedBag(itemLocation)
    if itemLocation and itemLocation.IsBagAndSlot and itemLocation:IsBagAndSlot() then
        return (itemLocation:GetBagAndSlot())
    end
    local focus = (GetMouseFoci and GetMouseFoci()[1]) or (GetMouseFocus and GetMouseFocus())
    if not focus then return nil end
    if focus.GetBagID then return focus:GetBagID() end
    local parent = focus:GetParent()
    if not parent then return nil end
    if parent == BankFrame or parent == BankSlotsFrame then return BANK_CONTAINER or -1 end
    return parent.GetID and parent:GetID()
end

-- Ctrl+right-click an item in your bags at a vendor: every stack of it in
-- your bags is sold, one stack at a time, then the total is printed.
local function SellAll(id)
    if selling then return end
    local _, link, _, _, _, _, _, _, _, _, price = ItemInfo(id)
    if not price or price <= 0 then
        Msg("%s can't be sold to a vendor.", link or "that item")
        return
    end
    local queue = {}
    for _, bag in ipairs(BAGS) do
        local ok, slots = pcall(NumSlots, bag)
        for slot = 1, (ok and slots or 0) do
            if SlotItem(bag, slot) == id then queue[#queue + 1] = { bag, slot } end
        end
    end
    if #queue == 0 then return end
    selling = true
    local before = GetMoney()
    local i = 1
    local sellTicker
    local function finish()
        if sellTicker then sellTicker:Cancel() end
        -- sales land a moment after each click, so count only once the bags
        -- have settled: nothing locked and no change for half a second (or
        -- 4 seconds at most)
        local waited, lastLeft, still = 0, -1, 0
        local function report()
            local left, busy = 0, false
            for _, q in ipairs(queue) do
                if SlotItem(q[1], q[2]) == id then
                    left = left + 1
                    if SlotLocked(q[1], q[2]) then busy = true end
                end
            end
            still = (left == lastLeft and not busy) and still + 0.25 or 0
            lastLeft = left
            waited = waited + 0.25
            if left > 0 and still < 0.5 and waited < 4 then
                C_Timer.After(0.25, report)
                return
            end
            selling = false
            local sold = #queue - left
            local gained = GetMoney() - before
            Msg("sold %d stack%s of %s%s%s", sold, sold == 1 and "" or "s", link or "it",
                gained > 0 and (" for " .. Coin(gained)) or "",
                left > 0 and string.format("; %d not sold.", left) or ".")
            QueueBags()
        end
        C_Timer.After(0.25, report)
    end
    sellTicker = C_Timer.NewTicker(0.15, function()
        if not merchantOpen then finish() return end
        local q = queue[i]
        if not q then finish() return end
        if SlotLocked(q[1], q[2]) then return end    -- try again next tick
        if SlotItem(q[1], q[2]) == id then UseItem(q[1], q[2]) end
        i = i + 1
    end)
end

local function OnModifiedItemClick(link, itemLocation)
    if merchantOpen and IsControlKeyDown() and not IsShiftKeyDown() and not IsAltKeyDown()
        and GetMouseButtonClicked and GetMouseButtonClicked() == "RightButton" then
        local id = LinkID(link)
        local bag = id and ClickedBag(itemLocation)
        if bag and not BANKSET[bag] then
            if DressUpFrame and DressUpFrame:IsShown() and HideUIPanel then HideUIPanel(DressUpFrame) end
            SellAll(id)
        end
        return
    end
    if not bankOpen or not IsControlKeyDown() or IsShiftKeyDown() or IsAltKeyDown() then return end
    local id = LinkID(link)
    local bag = id and ClickedBag(itemLocation)
    if not bag then return end
    if DressUpFrame and DressUpFrame:IsShown() and HideUIPanel then HideUIPanel(DressUpFrame) end
    if BANKSET[bag] then
        MoveItems(BANK, BAGS, "withdraw", id)
    else
        MoveItems(BAGS, BANK, "deposit", id)
    end
end

-- Two buttons under the bank window, each with a picture of what it does:
-- bag -> bank (deposit) and bank -> bag (withdraw).
local function CreateBankButtons()
    local parent = BankFrame
    if not parent or bankButtons then return end
    local function Button(file, label, tip, onClick)
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetSize(150, 26)
        b:SetText(string.format("|TInterface\\AddOns\\%s\\media\\%s:16:32:0:0:128:64:0:128:0:64|t  %s",
            ADDON, file, label))
        b:SetScript("OnClick", onClick)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(label, 1, 1, 1)
            GameTooltip:AddLine(tip, nil, nil, nil, true)
            GameTooltip:AddLine("Tip: Ctrl+click a single item to move every stack of just that item.", 0.6, 0.6, 0.6, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        return b
    end
    local dep = Button("deposit", "Deposit",
        "Move every item in your bags that your bank already has into the bank.",
        function() MoveItems(BAGS, BANK, "deposit") end)
    local wd = Button("withdraw", "Withdraw",
        "Move every item in your bank that your bags already have into your bags.",
        function() MoveItems(BANK, BAGS, "withdraw") end)
    dep:SetPoint("TOPRIGHT", parent, "BOTTOM", -3, -4)
    wd:SetPoint("TOPLEFT", parent, "BOTTOM", 3, -4)
    bankButtons = { dep, wd }
    SetBankButtonsEnabled(not moving)
end

local function ScanEquip()
    local t = {}
    for slot = 1, 19 do
        local id = GetInventoryItemID("player", slot)
        if id then t[id] = (t[id] or 0) + 1 end
    end
    Me().equip = t
end

local function ScanMail()
    local t = {}
    for i = 1, (GetInboxNumItems() or 0) do
        for a = 1, (ATTACHMENTS_MAX_RECEIVE or 12) do
            local id = LinkID(GetInboxItemLink(i, a))
            if id then
                local _, _, _, n = GetInboxItem(i, a)
                t[id] = (t[id] or 0) + ((type(n) == "number" and n > 0) and n or 1)
            end
        end
    end
    Me().mail = t
end

---------------------------------------------------------------------------
-- Auction house scanning
---------------------------------------------------------------------------
local function Prices()
    local p = DB.prices[priceKey]
    if not p then p = { items = {} }; DB.prices[priceKey] = p end
    return p
end

local function Accessors()
    if QueryAuctionItems then
        return function() return GetNumAuctionItems("list") end,
               function(i) return GetAuctionItemInfo("list", i) end
    end
    return C_AuctionHouse.GetNumReplicateItems,
           function(i) return C_AuctionHouse.GetReplicateItemInfo(i - 1) end
end

-- Progress indicator: one line of text and a thin bar just above the top edge
-- of the auction house window. It hides with the window.
local BAR_W = 220
local bar, waitTicker, scanStart

local function ProgressUI()
    if bar then return bar end
    local parent = AuctionHouseFrame or AuctionFrame
    if not parent then return nil end
    bar = CreateFrame("Frame", nil, parent)
    bar:SetSize(BAR_W, 20)
    bar:SetPoint("BOTTOM", parent, "TOP", 0, 6)
    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetPoint("TOP")
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(1, 1, 1, 0.12)
    track:SetPoint("BOTTOMLEFT")
    track:SetPoint("BOTTOMRIGHT")
    track:SetHeight(3)
    bar.fill = bar:CreateTexture(nil, "ARTWORK")
    bar.fill:SetColorTexture(0.2, 1, 0.6, 0.9)
    bar.fill:SetPoint("BOTTOMLEFT")
    bar.fill:SetHeight(3)
    bar:Hide()
    return bar
end

-- frac: 0..1 fills the bar, nil hides the fill. hideAfter: seconds, or nil to stay.
-- On the Sell tab? Posting doesn't work while a full scan is running (the
-- game's sell window errors when you click Post), so automatic scans wait
-- until you're off it, and the bar warns you if you go there mid-scan.
local function SellOpen()
    local ah = AuctionHouseFrame
    if not ah then return false end
    return (ah.CommoditiesSellFrame and ah.CommoditiesSellFrame:IsShown())
        or (ah.ItemSellFrame and ah.ItemSellFrame:IsShown()) or false
end

local function ShowProgress(text, frac, hideAfter)
    local b = ProgressUI()
    if not b then return end
    if scanning and SellOpen() then text = text .. "  |cffff8040posting after the scan|r" end
    b.text:SetText(text)
    if frac then
        b.fill:SetWidth(math.max(0.001, BAR_W * math.min(frac, 1)))
        b.fill:Show()
    else
        b.fill:Hide()
    end
    b:Show()
    b.token = (b.token or 0) + 1
    if hideAfter then
        local token = b.token
        C_Timer.After(hideAfter, function() if b.token == token then b:Hide() end end)
    end
end

local function StopWaiting()
    if waitTicker then waitTicker:Cancel(); waitTicker = nil end
end

local function Elapsed() return math.floor(GetTime() - (scanStart or GetTime()) + 0.5) end

local Comma = BreakUpLargeNumbers or tostring

-- Scan log: every step of the last scans, for /fitp scanlog
local scanLog = {}
local function Log(fmt, ...)
    local t = date("%H:%M:%S") .. (scanStart and string.format(" +%.0fs", GetTime() - scanStart) or "")
    local text = string.format(fmt, ...)
    -- the same message again: count it instead of adding a line
    local prev = scanLog[#scanLog]
    if prev and scanLog.lastText == text then
        scanLog.repeats = (scanLog.repeats or 1) + 1
        scanLog[#scanLog] = scanLog.lastLine .. string.format("  (x%d)", scanLog.repeats)
        return
    end
    scanLog.lastText, scanLog.repeats = text, 1
    scanLog.lastLine = t .. "  " .. text
    scanLog[#scanLog + 1] = scanLog.lastLine
    if #scanLog > 80 then table.remove(scanLog, 1) end
end

local function Process()
    StopWaiting()
    local getN, getInfo = Accessors()
    local n = getN() or 0
    Log("reading results: %d auctions", n)
    if n == 0 then
        scanning = false
        Msg("the scan came back empty; it will retry later.")
        ShowProgress("Scan came back empty; will retry", nil, 5)
        return
    end
    local items, byName, i, missing = {}, {}, 1, 0
    local function step()
        -- stop if the AH closed or a normal search replaced the results
        if not ahOpen or (getN() or 0) ~= n then
            Log("interrupted at %d/%d: AH open=%s, count now %s", i, n, tostring(ahOpen), tostring(getN()))
            scanning = false
            Msg("scan interrupted; it will retry later.")
            ShowProgress("Scan interrupted; will retry", nil, 5)
            return
        end
        ShowProgress(string.format("Scanning: reading auctions  %d%%", math.floor((i - 1) / n * 100)), (i - 1) / n)
        local last = math.min(i + 2499, n)
        for j = i, last do
            local iname, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, id, hasAll = getInfo(j)
            if hasAll == false then missing = missing + 1 end
            if iname and id and iname ~= "" then
                DB.itemNames[iname] = id
                if buyout and buyout > 0 then
                    local e = math.floor(buyout / math.max(count or 1, 1))
                    if not byName[iname] or e < byName[iname] then byName[iname] = e end
                end
            end
            if id and buyout and buyout > 0 then
                local each = math.floor(buyout / math.max(count or 1, 1))
                if not items[id] or each < items[id] then items[id] = each end
            end
        end
        i = last + 1
        if i <= n then
            C_Timer.After(0, step)
        else
            local p = Prices()
            p.items, p.byName, p.time = items, byName, time()
            scanning = false
            local k = 0
            for _ in pairs(items) do k = k + 1 end
            Msg("scanned %d auctions (%d items).", n, k)
            Log("complete: %d auctions, %d items; %d entries lacked item info (each one asks the server)", n, k, missing)
            ShowProgress(string.format("Scan complete: %s auctions in %ds", Comma(n), Elapsed()), 1, 5)
        end
    end
    step()
end

local SCAN_TIMEOUT = 300
local OnScanDataRef                         -- set once OnScanData is defined below

local function TryScan(manual)
    if not ahOpen then return end
    if scanning then
        if manual then Msg("already scanning.") end
        return
    end
    local function why(text) if manual then Log("not started: %s", text) end end
    local p = Prices()
    -- the server quietly ignores a full scan asked for within 15 minutes of
    -- the last request (finished or not), and the auction house can then stay
    -- stuck until relog, so never ask sooner. p.asked survives reloads.
    local sinceAsk = p.asked and time() - p.asked
    if not manual then
        if not DB.auto or (p.time and time() - p.time < MIN_RESCAN) then return end
        if SellOpen() then return end           -- try again when you're off the Sell tab
        if sinceAsk and sinceAsk < SERVER_COOLDOWN then return end
    elseif sinceAsk and sinceAsk < SERVER_COOLDOWN then
        local wait = math.ceil((SERVER_COOLDOWN - sinceAsk) / 60)
        Msg("the server allows one full scan every 15 minutes; try again in %d min.", wait)
        why("within the server's 15 minute cooldown")
        return
    end
    if QueryAuctionItems then
        local _, canAll = CanSendAuctionQuery()
        if not canAll then
            if manual then Msg("the server allows one full scan every 15 minutes; try again shortly.") end
            why("server says no full scan allowed yet")
            return
        end
        scanning, awaiting = true, true
        scanStart = GetTime()
        Log("asked the server (old API, QueryAuctionItems getAll)%s", manual and ", manual" or "")
        p.asked = time()
        QueryAuctionItems("", nil, nil, 0, false, nil, true, false, nil)
    elseif C_AuctionHouse and C_AuctionHouse.ReplicateItems then
        scanning, awaiting = true, true
        scanStart = GetTime()
        Log("asked the server (C_AuctionHouse.ReplicateItems)%s; items already there: %s",
            manual and ", manual" or "", tostring(C_AuctionHouse.GetNumReplicateItems()))
        p.asked = time()
        C_AuctionHouse.ReplicateItems()
    else
        why("no scan API found")
        return
    end
    Msg("scanning the auction house...")
    ShowProgress("Scanning: waiting for server  0s")
    StopWaiting()
    -- Don't rely only on the server's "results ready" event: watch the count
    -- of auctions received, and once it's stopped growing for 4 seconds,
    -- read them anyway.
    local getN = Accessors()
    local lastN, steady, sinceCheck = getN() or 0, 0, 0
    local startN = lastN
    waitTicker = C_Timer.NewTicker(0.25, function()
        local n = getN() or 0
        ShowProgress(n > startN and string.format("Scanning: receiving  %s auctions  %ds", Comma(n), Elapsed())
            or string.format("Scanning: waiting for server  %ds", Elapsed()))
        sinceCheck = sinceCheck + 0.25
        if sinceCheck < 1 then return end
        sinceCheck = 0
        if n ~= lastN then
            Log("receiving: %d auctions so far", n)
            lastN, steady = n, 0
        elseif n > startN then
            steady = steady + 1
            if steady >= 4 and awaiting then
                Log("count steady at %d for 4s with no results event: reading them", n)
                OnScanDataRef("count steady")
            end
        end
    end)
    -- A big auction house can take the server a few minutes to send. Asking
    -- again restarts its work, so wait up to 5 minutes before giving up.
    local token = scanStart
    C_Timer.After(SCAN_TIMEOUT, function()
        if awaiting and scanStart == token then
            awaiting, scanning = false, false
            StopWaiting()
            Msg("the server didn't answer within %d minutes; will retry.", SCAN_TIMEOUT / 60)
            Log("timed out after %ds with no results event", SCAN_TIMEOUT)
            ShowProgress("Scan timed out; will retry", nil, 5)
        end
    end)
end

local function OnScanData(event)
    local getN = Accessors()
    Log("%s: waiting=%s, %s auctions", event or "results event", tostring(awaiting), tostring(getN and getN()))
    if not awaiting then return end
    awaiting = false
    C_Timer.After(1, Process)
end
OnScanDataRef = OnScanData

---------------------------------------------------------------------------
-- Disenchanting: what an armor or weapon piece is worth on average when
-- disenchanted, from the Classic disenchant tables (by item level, quality,
-- and armor vs weapon) and the materials' prices from the last AH scan.
---------------------------------------------------------------------------
local M = {
    STRANGE = 10940, SOUL = 11083, VISION = 11137, DREAM = 11176, ILLUSION = 16204,
    LMAGIC = 10938, GMAGIC = 10939, LASTRAL = 10998, GASTRAL = 11082, LMYSTIC = 11134,
    GMYSTIC = 11135, LNETHER = 11174, GNETHER = 11175, LETERNAL = 16202, GETERNAL = 16203,
    SGLIMMER = 10978, LGLIMMER = 11084, SGLOW = 11138, LGLOW = 11139, SRADIANT = 11177,
    LRADIANT = 11178, SBRILLIANT = 14343, LBRILLIANT = 14344, NEXUS = 20725,
}
-- uncommon: up to item level, { dust, min, max }, { essence, min, max }, shard
local DE_UNCOMMON = {
    { 15, { M.STRANGE, 1, 2 }, { M.LMAGIC, 1, 2 } },
    { 20, { M.STRANGE, 2, 3 }, { M.GMAGIC, 1, 2 }, M.SGLIMMER },
    { 25, { M.STRANGE, 4, 6 }, { M.LASTRAL, 1, 2 }, M.SGLIMMER },
    { 30, { M.SOUL, 1, 2 }, { M.GASTRAL, 1, 2 }, M.LGLIMMER },
    { 35, { M.SOUL, 2, 5 }, { M.LMYSTIC, 1, 2 }, M.SGLOW },
    { 40, { M.VISION, 1, 2 }, { M.GMYSTIC, 1, 2 }, M.LGLOW },
    { 45, { M.VISION, 2, 5 }, { M.LNETHER, 1, 2 }, M.SRADIANT },
    { 50, { M.DREAM, 1, 2 }, { M.GNETHER, 1, 2 }, M.LRADIANT },
    { 55, { M.DREAM, 2, 5 }, { M.LETERNAL, 1, 2 }, M.SBRILLIANT },
    { 60, { M.ILLUSION, 1, 2 }, { M.GETERNAL, 1, 2 }, M.LBRILLIANT },
    { 999, { M.ILLUSION, 2, 5 }, { M.GETERNAL, 2, 3 }, M.LBRILLIANT },
}
-- rare and epic: up to item level, list of { material, chance, min, max }
local DE_RARE = {
    { 25, { { M.SGLIMMER, 1, 1, 1 } } }, { 30, { { M.LGLIMMER, 1, 1, 1 } } },
    { 35, { { M.SGLOW, 1, 1, 1 } } },    { 40, { { M.LGLOW, 1, 1, 1 } } },
    { 45, { { M.SRADIANT, 1, 1, 1 } } }, { 50, { { M.LRADIANT, 1, 1, 1 } } },
    { 55, { { M.SBRILLIANT, 1, 1, 1 } } },
    { 999, { { M.LBRILLIANT, 0.995, 1, 1 }, { M.NEXUS, 0.005, 1, 1 } } },
}
local DE_EPIC = {
    { 45, { { M.SRADIANT, 1, 2, 4 } } }, { 50, { { M.LRADIANT, 1, 2, 4 } } },
    { 55, { { M.SBRILLIANT, 1, 2, 4 } } }, { 60, { { M.NEXUS, 1, 1, 1 } } },
    { 999, { { M.NEXUS, 1, 1, 2 } } },
}

local function DisenchantOutcomes(id)
    local _, _, quality, level, _, _, _, _, _, _, _, classID = ItemInfo(id)
    if not (quality and level) or (classID ~= 2 and classID ~= 4) then return nil end
    local function pick(t) for _, row in ipairs(t) do if level <= row[1] then return row end end end
    if quality == 2 then
        local row = pick(DE_UNCOMMON)
        local weapon = classID == 2
        local dustP, essP = weapon and 0.20 or 0.75, weapon and 0.75 or 0.20
        if not row[4] then dustP, essP = weapon and 0.20 or 0.80, weapon and 0.80 or 0.20 end
        local out = { { row[2][1], dustP, row[2][2], row[2][3] }, { row[3][1], essP, row[3][2], row[3][3] } }
        if row[4] then out[3] = { row[4], 0.05, 1, 1 } end
        return out
    elseif quality == 3 and level >= 11 then
        return pick(DE_RARE)[2]
    elseif quality == 4 and level >= 40 then
        return pick(DE_EPIC)[2]
    end
end

-- average value of disenchanting one, and whether some material had no price
local function DisenchantValue(id, p)
    local outs = DisenchantOutcomes(id)
    if not outs then return nil end
    local v, partial, any = 0, false, false
    for _, o in ipairs(outs) do
        local price = p.items[o[1]]
        if price then
            v = v + o[2] * (o[3] + o[4]) / 2 * price
            any = true
        else
            partial = true
        end
    end
    if not any then return nil, true end
    return math.floor(v + 0.5), partial
end

local ItemCost                              -- crafting cost of an item (defined with the professions code)
local AddCrateLine                          -- Waylaid Crates (defined below)
local AddWritLine                           -- Craftsman's Writs (defined below)

local function AddDisenchantLine(tt, id)
    local p = DB.prices[priceKey]
    if not (p and p.time) then return end
    local ok, v, partial = pcall(DisenchantValue, id, p)
    if not ok then return end
    -- labelled with the scan's age, like the AH line (red once it's stale)
    local age = time() - p.time
    local label = "Disenchant " .. (age > STALE and "|cffff3333" or "|cff808080") .. Ago(age) .. "|r"
    if v then
        tt:AddDoubleLine(label, Coin(v) .. (partial and "|cff808080 +?|r" or ""), 1, .82, 0, 1, 1, 1)
    elseif partial then
        tt:AddDoubleLine(label, "|cff808080materials not on the AH|r", 1, .82, 0, 1, 1, 1)
    end
end

---------------------------------------------------------------------------
-- Tooltips
---------------------------------------------------------------------------
-- the game's "Sell Price" line, moved down here just above the AH price
-- (only once the game's own line has been taken over, so it's never shown twice)
local sellMoved = false
-- vendor price for ONE of the item (the game's own line is for the whole stack)
local function VendorEach(tt, id)
    local each = ItemInfo and select(11, ItemInfo(id))
    if each then return each end
    -- item info not loaded yet: the game's stack price, divided by the stack
    local price = tt.fitpSellPrice
    if not price or price == 0 then return price end
    local owner = tt.GetOwner and tt:GetOwner()
    local ok, bag, slot = pcall(function() return owner:GetBagID(), owner:GetID() end)
    if ok and bag and slot and C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info and info.stackCount and info.stackCount > 1 then
            return math.floor(price / info.stackCount + 0.5)
        end
    end
    return price
end
-- how many are in the hovered stack (1 unless it's a stack in your bags or bank)
local function StackCount(tt)
    local owner = tt.GetOwner and tt:GetOwner()
    local ok, bag, slot = pcall(function() return owner:GetBagID(), owner:GetID() end)
    if ok and bag and slot and C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info and info.stackCount and info.stackCount > 1 then return info.stackCount end
    end
    return 1
end
-- " x20" after a price label for a stack
local function StackTag(n) return n > 1 and (" x" .. n) or "" end

local function AddVendorLine(tt, id)
    if not sellMoved then return end
    local price = VendorEach(tt, id)
    if price and price > 0 then
        local n = StackCount(tt)
        tt:AddDoubleLine("Vendor" .. StackTag(n), Coin(price * n), 1, .82, 0, 1, 1, 1)
    end
end

-- where the hovered item is sitting, when that's one of your own slots:
-- "bags" or "bank" for a bag / bank slot, "equip" for a character slot
local function HoverLocation(tt)
    local owner = tt.GetOwner and tt:GetOwner()
    if not owner then return nil end
    local ok, bag = pcall(function() return owner.GetBagID and owner:GetBagID() end)
    if ok and bag then return BANKSET[bag] and "bank" or "bags" end
    local name = owner.GetName and owner:GetName()
    if name and name:match("^Character.+Slot$") then return "equip" end
    return nil
end

local function AddItemLines(tt, id)
    local started, total, rows = false, 0, 0
    local list = {}
    for _, k in ipairs(SortedChars()) do
        local c = DB.chars[k]
        local parts, sum, where = {}, 0, {}
        for _, loc in ipairs(LOCS) do
            local n = c[loc] and c[loc][id]
            if n and n > 0 then
                parts[#parts + 1] = ICON[loc] .. " " .. n
                sum = sum + n
                where[#where + 1] = loc
            end
        end
        if sum > 0 then list[#list + 1] = { c = c, parts = parts, sum = sum, where = where } end
    end
    -- nothing new to say: only you have it, all of it in the very place you're
    -- looking at (e.g. your one Peacebloom, hovered in your bags)
    local hidden = false
    if #list == 1 and list[1].c == Me() and #list[1].where == 1 then
        local here = HoverLocation(tt)
        hidden = here ~= nil and here == list[1].where[1]
    end
    if not hidden then
        for _, row in ipairs(list) do
            if not started then tt:AddLine(" "); started = true end
            tt:AddDoubleLine(ColoredName(row.c), table.concat(row.parts, "   "), 1, 1, 1, 1, 1, 1)
            total, rows = total + row.sum, rows + 1
        end
    end

    local bind = ItemInfo and select(14, ItemInfo(id))
    if bind == 1 or bind == 4 then -- bind on pickup / quest items can't be sold, but can be disenchanted
        local vendor = sellMoved and VendorEach(tt, id)
        local de = DisenchantOutcomes(id) and DB.prices[priceKey]
        if (vendor and vendor > 0) or de then
            tt:AddLine(" ")                        -- a gap before the prices
            AddVendorLine(tt, id)
            if de then AddDisenchantLine(tt, id) end
        end
        return
    end
    tt:AddLine(" ")                                -- a gap before the prices
    AddVendorLine(tt, id)
    local p = DB.prices[priceKey]
    if p and p.time then
        local age = time() - p.time
        local n = StackCount(tt)
        local label = "AH" .. StackTag(n) .. " " .. (age > STALE and "|cffff3333" or "|cff808080") .. Ago(age) .. "|r"
        local v = p.items[id]
        tt:AddDoubleLine(label, v and Coin(v * n) or "|cff808080none listed|r", 1, .82, 0, 1, 1, 1)
        AddDisenchantLine(tt, id)
        AddCrateLine(tt, id)
        AddWritLine(tt, id)
    else
        tt:AddDoubleLine("AH", "|cff808080no scan yet|r", 1, .82, 0, 1, 1, 1)
    end
end

---------------------------------------------------------------------------
-- Waylaid Crates: each takes ONE of several fills (e.g. 20 Peacebloom or
-- 10 Briarthorn). The tooltip shows the cheapest one at the last AH scan's
-- prices, or what it costs to craft if you can make it for less.
-- (Crate contents from foreverdiff.com; fill items by ID, double-checked by
-- name in game where the item is known.)
---------------------------------------------------------------------------
local CRATES = {
    [248685] = { { 20, 10940, "Strange Dust" }, { 4, 10939, "Greater Magic Essence" }, { 6, 10978, "Small Glimmering Shard" }, { 2, 11084, "Large Glimmering Shard" } },
    [248702] = { { 2, 4231, "Cured Light Hide" }, { 20, 2996, "Bolt of Linen Cloth" } },
    [248682] = { { 20, 2447, "Peacebloom" }, { 20, 765, "Silverleaf" }, { 10, 2449, "Earthroot" }, { 10, 785, "Mageroyal" }, { 10, 2450, "Briarthorn" } },
    [248703] = { { 20, 2840, "Copper Bar" }, { 20, 3576, "Tin Bar" }, { 10, 2841, "Bronze Bar" } },
    [248683] = { { 20, 2770, "Copper Ore" }, { 20, 2771, "Tin Ore" } },
    [248704] = { { 16, 4359, "Handful of Copper Bolts" }, { 16, 4361, "Copper Tube" }, { 4, 4363, "Copper Modulator" } },
    [248684] = { { 40, 2589, "Linen Cloth" }, { 20, 2318, "Light Leather" } },
    [248689] = { { 20, 11083, "Soul Dust" }, { 4, 11082, "Greater Astral Essence" }, { 6, 11138, "Small Glowing Shard" }, { 2, 11139, "Large Glowing Shard" } },
    [248705] = { { 6, 2997, "Bolt of Woolen Cloth" }, { 10, 4305, "Bolt of Silk Cloth" }, { 2, 4233, "Cured Medium Hide" } },
    [248686] = { { 10, 3820, "Stranglekelp" }, { 10, 2453, "Bruiseweed" }, { 10, 3355, "Wild Steelbloom" }, { 10, 3369, "Grave Moss" }, { 10, 3356, "Kingsblood" } },
    [248706] = { { 10, 2842, "Silver Bar" }, { 20, 3575, "Iron Bar" } },
    [248687] = { { 10, 2775, "Silver Ore" }, { 20, 2772, "Iron Ore" } },
    [248707] = { { 8, 4371, "Bronze Tube" }, { 7, 4375, "Whirring Bronze Gizmo" }, { 4, 4382, "Bronze Framework" }, { 45, 10558, "Gold Power Core" } },
    [248688] = { { 20, 2592, "Wool Cloth" }, { 40, 4306, "Silk Cloth" }, { 20, 2319, "Medium Leather" } },
    [248690] = { { 20, 3357, "Liferoot" }, { 10, 3818, "Fadeleaf" }, { 10, 3821, "Goldthorn" }, { 10, 3358, "Khadgar's Whisker" } },
    [248694] = { { 20, 11137, "Vision Dust" }, { 4, 11135, "Greater Mystic Essence" }, { 6, 11177, "Small Radiant Shard" }, { 2, 11178, "Large Radiant Shard" } },
    [248708] = { { 8, 4339, "Bolt of Mageweave" }, { 2, 4236, "Cured Heavy Hide" } },
    [248709] = { { 20, 3860, "Mithril Bar" }, { 15, 3859, "Steel Bar" }, { 10, 3577, "Gold Bar" } },
    [248692] = { { 10, 2776, "Gold Ore" }, { 20, 3858, "Mithril Ore" } },
    [248710] = { { 8, 4387, "Iron Strut" }, { 5, 10559, "Mithril Tube" }, { 12, 10560, "Unstable Trigger" }, { 5, 10561, "Mithril Casing" } },
    [248693] = { { 40, 4338, "Mageweave Cloth" }, { 20, 4234, "Heavy Leather" } },
    [248691] = { { 10, 3819, "Wintersbite" }, { 10, 4625, "Firebloom" }, { 20, 8831, "Purple Lotus" }, { 10, 8836, "Arthas' Tears" } },
    [248699] = { { 20, 11176, "Dream Dust" }, { 4, 11175, "Greater Nether Essence" }, { 6, 14343, "Small Brilliant Shard" }, { 2, 14344, "Large Brilliant Shard" } },
    [248711] = { { 8, 14048, "Bolt of Runecloth" }, { 2, 8172, "Cured Thick Hide" } },
    [248712] = { { 2, 11371, "Dark Iron Bar" }, { 10, 6037, "Truesilver Bar" }, { 20, 12359, "Thorium Bar" } },
    [248697] = { { 10, 7911, "Truesilver Ore" }, { 20, 10620, "Thorium Ore" }, { 20, 11370, "Dark Iron Ore" } },
    [248713] = { { 5, 15994, "Thorium Widget" }, { 5, 18631, "Truesilver Transformer" }, { 2, 16000, "Thorium Tube" } },
    [248698] = { { 40, 14047, "Runecloth" }, { 20, 4304, "Thick Leather" }, { 20, 8170, "Rugged Leather" } },
    [248695] = { { 10, 13464, "Golden Sansam" }, { 20, 8838, "Sungrass" }, { 10, 8839, "Blindweed" }, { 10, 8845, "Ghost Mushroom" }, { 10, 8846, "Gromsblood" } },
    [248696] = { { 20, 13463, "Dreamfoil" }, { 20, 13465, "Mountain Silversage" }, { 20, 13466, "Plaguebloom" }, { 20, 13467, "Icecap" } },
}

-- the item ID for a fill, checked against its name when the game knows it
local function FillID(f)
    local id, name = f[2], f[3]
    local known = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
    if known == name then return id end
    local lookup = GetItemInfo or (C_Item and C_Item.GetItemInfo)
    if lookup then                              -- our ID is off or unknown: look it up by name
        local ok, _, link = pcall(lookup, name)
        local byName = ok and LinkID(link)
        if byName then return byName end
    end
    return id
end

AddCrateLine = function(tt, id)
    local fills = CRATES[id]
    if not fills then return end
    local p = DB.prices[priceKey]
    if not (p and p.time) then return end
    local best, bestFill, bestCrafted
    for _, f in ipairs(fills) do
        local fid = FillID(f)
        local each, crafted = p.items[fid], false
        if Me().crafts and Me().crafts[fid] then          -- you can make it: is that cheaper?
            local ok, c = pcall(ItemCost, fid, p, {}, {}, 0, {})
            if ok and c and (not each or c < each) then each, crafted = c, true end
        end
        if each then
            local total = each * f[1]
            if not best or total < best then best, bestFill, bestCrafted = total, f, crafted end
        end
    end
    local age = time() - p.time
    local label = "Cheapest fill " .. (age > STALE and "|cffff3333" or "|cff808080") .. Ago(age) .. "|r"
    if best then
        tt:AddDoubleLine(label, Coin(math.floor(best + 0.5)), 1, .82, 0, 1, 1, 1)
        tt:AddDoubleLine("   " .. bestFill[1] .. " x " .. bestFill[3]
            .. (bestCrafted and " |cff808080(made yourself)|r" or ""), " ", 1, 1, 1, 1, 1, 1)
    else
        tt:AddDoubleLine(label, "|cff808080none of its fills are on the AH|r", 1, .82, 0, 1, 1, 1)
    end
end

---------------------------------------------------------------------------
-- Craftsman's Writs. WoW Forever's writs ("Craftsman's Writ: Heavy Leather
-- Ball") are world drops that each ask for one of an item. The tooltip shows
-- its price at the last AH scan, and what it costs to make yourself if you
-- know the recipe. The original Light's Hope writs ("Craftsman's Writ -
-- Dense Weightstone") ask for set amounts.
---------------------------------------------------------------------------
local OLD_WRITS = {
    ["Potion of Petrification"] = 1, ["Greater Arcane Protection Potion"] = 15,
    ["Major Healing Potion"] = 20, ["Major Mana Potion"] = 10, ["Dense Weightstone"] = 120,
    ["Huge Thorium Battleaxe"] = 3, ["Imperial Plate Chest"] = 3, ["Volcanic Hammer"] = 3,
    ["Radiant Circlet"] = 3, ["Thorium Grenade"] = 20, ["Thorium Tube"] = 14,
    ["Gnomish Battle Chicken"] = 4, ["Goblin Sapper Charge"] = 20, ["Lightning Eel"] = 30,
    ["Plated Armorfish"] = 30, ["Stonescale Eel"] = 40, ["Rugged Armor Kit"] = 25,
    ["Runic Leather Pants"] = 4, ["Wicked Leather Belt"] = 10, ["Wicked Leather Headband"] = 10,
    ["Brightcloth Pants"] = 6, ["Runecloth Bag"] = 8, ["Runecloth Boots"] = 8, ["Runecloth Robe"] = 8,
}

-- what a writ asks for, and how many
local function WritWants(writName)
    if not writName then return end
    local want = writName:match("^Craftsman's Writ: (.+)$")
    if want then return want, 1 end
    want = writName:match("^Craftsman's Writ %- (.+)$")
    if want and OLD_WRITS[want] then return want, OLD_WRITS[want] end
end

-- Names for the items in your saved prices, so a writ (which only names its
-- item) can find the price. Item names load from the server in the
-- background, so this runs twice: once at login and again a minute later.
local function LearnPricedNames()
    local p = DB.prices[priceKey]
    if not (p and p.items and C_Item and C_Item.GetItemNameByID) then return end
    local ids = {}
    for id in pairs(p.items) do ids[#ids + 1] = id end
    local i = 1
    local function step()
        for j = i, math.min(i + 199, #ids) do
            local n = C_Item.GetItemNameByID(ids[j])
            if n then DB.itemNames[n] = ids[j] end
        end
        i = i + 200
        if i <= #ids then C_Timer.After(0, step) end
    end
    step()
end

-- the item ID for a name: from the game if it knows it, else from a scan or your recipes
local function IDForName(name)
    local lookup = GetItemInfo or (C_Item and C_Item.GetItemInfo)
    if lookup then
        local ok, _, link = pcall(lookup, name)
        local id = ok and LinkID(link)
        if id then DB.itemNames[name] = id; return id end
    end
    return DB.itemNames[name]
end

AddWritLine = function(tt, id)
    local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
    if not name then name = tt.GetItem and tt:GetItem() end
    local want, n = WritWants(name)
    if not want then return end
    local p = DB.prices[priceKey]
    tt:AddDoubleLine("Writ: " .. (n > 1 and (n .. " x ") or "") .. want, " ", 1, .82, 0, 1, 1, 1)
    if not (p and p.time) then return end
    local fid = IDForName(want)
    local age = time() - p.time
    local ageText = (age > STALE and "|cffff3333" or "|cff808080") .. Ago(age) .. "|r"
    local mult = n
    -- the price by the item's name (saved by the scan), else by its ID
    local each = (p.byName and p.byName[want]) or (fid and p.items[fid])
    tt:AddDoubleLine("   Buy on AH " .. ageText,
        each and Coin(math.floor(each * mult + 0.5))
            or "|cff808080not on the AH|r", 1, 1, 1, 1, 1, 1)
    if fid and Me().crafts and Me().crafts[fid] then
        local ok, c = pcall(ItemCost, fid, p, {}, {}, 0, {})
        tt:AddDoubleLine("   Make yourself",
            ok and c and Coin(math.floor(c * mult + 0.5)) or "|cff808080reagents not on the AH|r", 1, 1, 1, 1, 1, 1)
    end
end

local function OnItemTooltip(tt, data)
    if not DB or tt.fitpDone then return end
    if tt ~= GameTooltip and tt ~= ItemRefTooltip then return end
    -- a recipe's tooltip has the item it makes inside it, and the game runs
    -- this for that inner item too: only count the item actually hovered
    if type(data) == "table" and data.id and tt.GetPrimaryTooltipData then
        local primary = tt:GetPrimaryTooltipData()
        if primary and primary.id and primary.id ~= data.id then return end
    end
    local _, link = tt:GetItem()
    local id = LinkID(link)
    if type(data) == "table" and data.id and data.id ~= id then id = data.id end
    if not id then return end
    tt.fitpDone = true
    AddItemLines(tt, id)
    tt:Show()
end

local function HookTooltips()
    local useProcessor = TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
        and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item
    if useProcessor then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
        -- the game's "Sell Price" line (for the whole stack): skip drawing it
        -- there; the price for one is shown above the AH price instead
        local sellType = Enum.TooltipDataLineType and Enum.TooltipDataLineType.SellPrice
        if sellType and TooltipDataProcessor.AddLinePreCall then
            TooltipDataProcessor.AddLinePreCall(sellType, function(tt, lineData)
                if tt ~= GameTooltip and tt ~= ItemRefTooltip then return end
                tt.fitpSellPrice = lineData and lineData.price or 0
                return true                       -- handled: the game doesn't add its own line
            end)
            sellMoved = true
        end
    end
    for _, tt in ipairs({ GameTooltip, ItemRefTooltip }) do
        tt:HookScript("OnTooltipCleared", function(self) self.fitpDone = nil; self.fitpSellPrice = nil end)
        if not useProcessor then tt:HookScript("OnTooltipSetItem", OnItemTooltip) end
    end
end

local function AddGoldLines(tt)
    tt:AddLine(" ")
    local total = 0
    for _, k in ipairs(SortedChars()) do
        local c = DB.chars[k]
        if (c.gold or 0) > 0 then
            tt:AddDoubleLine(ColoredName(c), Coin(c.gold), 1, 1, 1, 1, 1, 1)
            total = total + c.gold
        end
    end
    tt:AddDoubleLine("Total", Coin(total), .6, .6, .6, 1, 1, 1)
end

local function HookGold(frame)
    if not frame or frame.fitpHooked then return end
    frame.fitpHooked = true
    frame:HookScript("OnEnter", function(self)
        if not GameTooltip:IsOwned(self) then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Gold", 1, .82, 0)
        end
        AddGoldLines(GameTooltip)
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function(self)
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
end

-- Hook a money display: the frame itself (if it takes the mouse) and its
-- gold/silver/copper buttons, found by name, by key, or by scanning children.
local function HookMoneyFrame(mf)
    if not mf then return end
    if mf.IsMouseEnabled and mf:IsMouseEnabled() then HookGold(mf) end
    local name = mf.GetName and mf:GetName()
    for _, s in ipairs({ "Gold", "Silver", "Copper" }) do
        HookGold(mf[s .. "Button"] or (name and _G[name .. s .. "Button"]))
    end
    for _, child in ipairs({ mf:GetChildren() }) do
        if child.IsObjectType and child:IsObjectType("Button") then HookGold(child) end
    end
end

local function HookAllMoney()
    HookGold(MainMenuBarBackpackButton)
    HookMoneyFrame(ContainerFrame1MoneyFrame)
    local cb = ContainerFrameCombinedBags
    if cb then
        HookMoneyFrame(cb.MoneyFrame or _G["ContainerFrameCombinedBagsMoneyFrame"])
        if not cb.fitpHooked then
            cb.fitpHooked = true
            -- some parts are built on first open, so hook again when it shows
            cb:HookScript("OnShow", function(self)
                HookMoneyFrame(self.MoneyFrame or _G["ContainerFrameCombinedBagsMoneyFrame"])
            end)
        end
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local H = {}

---------------------------------------------------------------------------
-- Crafting cost on the professions window: the selected recipe's reagents
-- at the last AH scan's prices, what the result sells for, and the profit.
-- Works with the trade skill window and the enchanting (craft) window.
---------------------------------------------------------------------------
local AH_CUT = 0.05                        -- the auction house keeps 5% of a sale

local function CostLine(parent, point, rel, relPoint, x, y)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(10, 14)
    f:SetPoint(point, rel, relPoint, x, y)
    f:EnableMouse(true)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.text:SetPoint("LEFT")
    f:SetScript("OnEnter", function(self)
        if not self.rows then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:AddLine("Crafting cost")
        for _, r in ipairs(self.rows) do
            GameTooltip:AddDoubleLine(r[1], r[2], 1, 1, 1, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", GameTooltip_Hide)
    return f
end

-- What one of an item costs you: if this character can make it, the cost of
-- its own reagents (all the way down), otherwise its AH price.
-- Returns cost (or nil), and adds names to missing / crafted.
ItemCost = function(id, p, missing, crafted, depth, seen)
    local recipe = Me().crafts and Me().crafts[id]
    if recipe and depth < 4 and not seen[id] and C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic then
        local ok, sch = pcall(C_TradeSkillUI.GetRecipeSchematic, recipe, false)
        if ok and sch and sch.reagentSlotSchematics then
            seen[id] = true
            local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic or 1
            local sum, subMissing = 0, {}
            for _, slot in ipairs(sch.reagentSlotSchematics) do
                if (slot.reagentType == basic or slot.required) and slot.reagents and slot.reagents[1] then
                    local rid = slot.reagents[1].itemID
                    local c = ItemCost(rid, p, subMissing, crafted, depth + 1, seen)
                    if c then sum = sum + c * (slot.quantityRequired or 1) end
                end
            end
            seen[id] = nil
            for _, m in ipairs(subMissing) do missing[#missing + 1] = m end
            local made = ((sch.quantityMin or 1) + (sch.quantityMax or sch.quantityMin or 1)) / 2
            local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ItemInfo(id) or "?"
            crafted[#crafted + 1] = name
            return sum / math.max(made, 1)
        end
    end
    local v = p.items[id]
    if v then return v end
    missing[#missing + 1] = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ItemInfo(id) or "?"
    return nil
end

-- api: numReagents(i), reagentInfo(i, r) -> name, tex, need, have, reagentLink(i, r), itemLink(i), numMade(i)
local function ShowCost(line, index, api)
    local function set(text, rows)
        line.text:SetText(text)
        line:SetWidth(math.max(10, line.text:GetStringWidth()))
        line.rows = rows
        if GameTooltip:IsOwned(line) then line:GetScript("OnEnter")(line) end
    end
    if not index or index == 0 then set("", nil) return end
    local p = DB.prices[priceKey]
    if not (p and p.time) then
        set("|cffffd100Crafting cost|r  |cff808080scan the auction house first|r", nil)
        return
    end
    local GRAY = "|cff808080"
    local rows, total, anyMissing = {}, 0, false
    for r = 1, api.numReagents(index) or 0 do
        local name, _, need = api.reagentInfo(index, r)
        need = need or 1
        local id = LinkID(api.reagentLink(index, r))
        local missing, crafted = {}, {}
        local each = id and ItemCost(id, p, missing, crafted, 0, {})
        local label = need .. " x " .. (name or "?")
        if #crafted > 0 then label = label .. GRAY .. "  made yourself|r" end
        if each then
            total = total + each * need
            local right = Coin(math.floor(each * need + 0.5))
            if #missing > 0 then right = right .. GRAY .. " +?|r" end
            rows[#rows + 1] = { label, right }
            if #missing > 0 then
                anyMissing = true
                rows[#rows + 1] = { GRAY .. "    not on the AH: " .. table.concat(missing, ", ") .. "|r", "" }
            end
        else
            anyMissing = true
            rows[#rows + 1] = { label, GRAY .. "not on the AH|r" }
        end
    end
    total = math.floor(total + 0.5)
    rows[#rows + 1] = { "|cffffd100Total|r", Coin(total) .. (anyMissing and (GRAY .. " +?|r") or "") }
    -- what it sells for, after the AH's cut
    local made = api.itemLink and LinkID(api.itemLink(index))
    local value = made and p.items[made]
    local headline
    if value then
        local lo, hi = 1, 1
        if api.numMade then lo, hi = api.numMade(index) end
        local count = ((lo or 1) + (hi or lo or 1)) / 2
        local net = math.floor(value * count * (1 - AH_CUT))
        local profit = net - total
        rows[#rows + 1] = { " ", " " }
        rows[#rows + 1] = { "Sells for (after 5% AH cut)", Coin(net) }
        local shown = profit >= 0 and ("|cff33ff33+" .. Coin(profit) .. "|r") or ("|cffff3333-" .. Coin(-profit) .. "|r")
        rows[#rows + 1] = { "Profit", shown }
        headline = "|cffffd100Profit|r  " .. shown .. (anyMissing and (GRAY .. " ?|r") or "")
    end
    local age = time() - p.time
    local ago = (age > STALE and "|cffff3333" or GRAY) .. Ago(age) .. "|r"
    rows[#rows + 1] = { " ", " " }
    rows[#rows + 1] = { GRAY .. "Prices from the AH scan|r", ago }
    headline = headline or ("|cffffd100Crafting cost|r  " .. Coin(total) .. (anyMissing and (GRAY .. " +?|r") or ""))
    set(headline .. "   " .. GRAY .. "scan|r " .. ago, rows)
end

local tradeLine, craftLine
local TRADE_API = {
    numReagents = function(i) return GetTradeSkillNumReagents(i) end,
    reagentInfo = function(i, r) return GetTradeSkillReagentInfo(i, r) end,
    reagentLink = function(i, r) return GetTradeSkillReagentItemLink(i, r) end,
    itemLink = function(i) return GetTradeSkillItemLink(i) end,
    numMade = function(i) return GetTradeSkillNumMade(i) end,
}
local CRAFT_API = {
    numReagents = function(i) return GetCraftNumReagents(i) end,
    reagentInfo = function(i, r) return GetCraftReagentInfo(i, r) end,
    reagentLink = function(i, r) return GetCraftReagentItemLink(i, r) end,
    itemLink = function(i) return GetCraftItemLink and GetCraftItemLink(i) end,
}

local function RefreshTrade()
    if tradeLine and TradeSkillFrame and TradeSkillFrame:IsShown() and GetTradeSkillSelectionIndex then
        pcall(ShowCost, tradeLine, GetTradeSkillSelectionIndex(), TRADE_API)
    end
end
local function RefreshCraft()
    if craftLine and CraftFrame and CraftFrame:IsShown() and GetCraftSelectionIndex then
        pcall(ShowCost, craftLine, GetCraftSelectionIndex(), CRAFT_API)
    end
end

local function HookProfessions()
    if TradeSkillFrame and not tradeLine and GetTradeSkillReagentInfo then
        -- under the reagents, inside the scrolling recipe details
        local rel = _G.TradeSkillReagent7 or _G.TradeSkillDetailScrollFrame
        tradeLine = CostLine(_G.TradeSkillDetailScrollChildFrame or TradeSkillFrame, "TOPLEFT", rel, "BOTTOMLEFT", 4, -6)
        if TradeSkillFrame_SetSelection then hooksecurefunc("TradeSkillFrame_SetSelection", RefreshTrade) end
        TradeSkillFrame:HookScript("OnShow", RefreshTrade)
    end
    if CraftFrame and not craftLine and GetCraftReagentInfo then
        local rel = _G.CraftReagent7 or _G.CraftDetailScrollFrame
        craftLine = CostLine(_G.CraftDetailScrollChildFrame or CraftFrame, "TOPLEFT", rel, "BOTTOMLEFT", 4, -6)
        if CraftFrame_SetSelection then hooksecurefunc("CraftFrame_SetSelection", RefreshCraft) end
        CraftFrame:HookScript("OnShow", RefreshCraft)
    end
end

-- The newer professions window (what WoW Forever uses): the recipe's
-- "schematic" lists its reagent slots and what it makes.
local modernLine, modernRecipe
local MODERN_API = {}
local function Schematic(recipeID)
    local ok, sch = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    return ok and sch or nil
end
local function BasicSlots(sch)
    local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic or 1
    local slots = {}
    for _, slot in ipairs(sch and sch.reagentSlotSchematics or {}) do
        if (slot.reagentType == basic or slot.required) and slot.reagents and slot.reagents[1] then
            slots[#slots + 1] = slot
        end
    end
    return slots
end
MODERN_API.numReagents = function(recipeID) return #BasicSlots(Schematic(recipeID)) end
MODERN_API.reagentInfo = function(recipeID, r)
    local slot = BasicSlots(Schematic(recipeID))[r]
    local id = slot and slot.reagents[1].itemID
    local name = id and ((C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ItemInfo(id))
    return name, nil, slot and slot.quantityRequired or 1
end
MODERN_API.reagentLink = function(recipeID, r)
    local slot = BasicSlots(Schematic(recipeID))[r]
    local id = slot and slot.reagents[1].itemID
    return id and ("item:" .. id) or nil
end
MODERN_API.itemLink = function(recipeID)
    local sch = Schematic(recipeID)
    return sch and sch.outputItemID and ("item:" .. sch.outputItemID) or nil
end
MODERN_API.numMade = function(recipeID)
    local sch = Schematic(recipeID)
    return sch and sch.quantityMin or 1, sch and sch.quantityMax or 1
end

local function LearnCrafts()
    if not (C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs) then return end
    local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
    if not ok or type(ids) ~= "table" then return end
    local crafts = Me().crafts or {}
    Me().crafts = crafts
    for _, rid in ipairs(ids) do
        local okI, info = pcall(C_TradeSkillUI.GetRecipeInfo, rid)
        if okI and info and info.learned then
            local sch = Schematic(rid)
            if sch and sch.outputItemID then
                crafts[sch.outputItemID] = rid
                local n = C_Item.GetItemNameByID and C_Item.GetItemNameByID(sch.outputItemID)
                if n then DB.itemNames[n] = sch.outputItemID end
            end
        end
    end
end

local function RefreshModern()
    if modernLine and modernRecipe and ProfessionsFrame and ProfessionsFrame:IsShown() then
        pcall(ShowCost, modernLine, modernRecipe, MODERN_API)
    end
end

-- Expected profit of one craft of a recipe (nil if the result has no AH
-- price), and whether some reagent had no price (so the real profit is lower).
local function RecipeCost(recipeID)
    local p = DB.prices[priceKey]
    if not (p and p.time) then return nil end
    local total, missing, crafted, any = 0, {}, {}, false
    for r = 1, MODERN_API.numReagents(recipeID) do
        local _, _, need = MODERN_API.reagentInfo(recipeID, r)
        local id = LinkID(MODERN_API.reagentLink(recipeID, r))
        local each = id and ItemCost(id, p, missing, crafted, 0, {})
        if each then total = total + each * (need or 1); any = true else missing[#missing + 1] = "?" end
    end
    if not any then return nil end
    return math.floor(total + 0.5), #missing > 0
end

local function RecipeProfit(recipeID)
    local p = DB.prices[priceKey]
    if not (p and p.time) then return nil end
    local sch = Schematic(recipeID)
    if not (sch and sch.outputItemID) then return nil end
    local value = p.items[sch.outputItemID]
    if not value then return nil end
    local total, missing, crafted = 0, {}, {}
    for r = 1, MODERN_API.numReagents(recipeID) do
        local _, _, need = MODERN_API.reagentInfo(recipeID, r)
        local id = LinkID(MODERN_API.reagentLink(recipeID, r))
        local each = id and ItemCost(id, p, missing, crafted, 0, {})
        if each then total = total + each * (need or 1) else missing[#missing + 1] = "?" end
    end
    local count = ((sch.quantityMin or 1) + (sch.quantityMax or sch.quantityMin or 1)) / 2
    return math.floor(value * count * (1 - AH_CUT) - total + 0.5), #missing > 0
end

-- short money for the narrow list, with the coin icons: 1(g)20(s), 35(s), 80(c)
local GOLD = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:1:0|t"
local SILVER = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:1:0|t"
local COPPER = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:1:0|t"
local function ShortMoney(c)
    local g, sv, cp = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    if g > 0 then return g .. GOLD .. (g < 10 and sv > 0 and (" " .. sv .. SILVER) or "") end
    if sv > 0 then return sv .. SILVER end
    return cp .. COPPER
end

local profitCache = {}
local function ProfitText(recipeID)
    local cached = profitCache[recipeID]
    if cached ~= nil then return cached or nil end
    local ok, cost, partial = pcall(RecipeCost, recipeID)
    local text = false
    if ok and cost then
        text = ShortMoney(cost) .. (partial and "|cff808080+?|r" or "")
    end
    profitCache[recipeID] = text
    return text or nil
end

-- shorten a row's name only if name + count + cost would overlap
local function FitLabel(row)
    local label, count = row.Label, row.Count
    if not (label and row.fitpGameWidth) then return end
    local rl, ll, rw = row:GetLeft(), label:GetLeft(), row:GetWidth()
    if not (rl and ll and rw and rw > 0) then
        if not row.fitpRetry then                 -- not laid out yet: try again next frame
            row.fitpRetry = true
            C_Timer.After(0, function() row.fitpRetry = false; FitLabel(row) end)
        end
        return
    end
    local countW = 0
    if count and count:IsShown() and (count:GetText() or "") ~= "" then
        countW = (count:GetStringWidth() or 0) + 4
    end
    local costW = row.fitpCostW or 0
    local room = rw - (ll - rl) - countW - (costW > 0 and costW + 12 or 6)
    local target = math.max(20, math.min(row.fitpGameWidth, room))
    row.fitpSizing = true
    label:SetWidth(target)
    row.fitpSizing = false
end

-- put each recipe's crafting cost at the right edge of its row in the recipe list
local function TagRow(row)
    local data = row.GetElementData and row:GetElementData()
    local node = data and data.GetData and data:GetData()
    local info = node and node.recipeInfo
    if not row.fitpProfit then
        -- a small hover area around the number (clicks still go to the row)
        local hover = CreateFrame("Frame", nil, row)
        hover:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        hover:SetHeight(14)
        if hover.SetMouseClickEnabled then
            hover:SetMouseMotionEnabled(true)
            hover:SetMouseClickEnabled(false)
        end
        hover:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Cost")
            GameTooltip:Show()
        end)
        hover:SetScript("OnLeave", GameTooltip_Hide)
        row.fitpProfit = hover:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.fitpProfit:SetPoint("RIGHT")
        row.fitpHover = hover
    end
    row.fitpProfit:SetText(info and info.recipeID and ProfitText(info.recipeID) or "")
    local costW = row.fitpProfit:GetStringWidth() or 0
    row.fitpHover:SetWidth(math.max(1, costW))
    -- Make room for the cost. Each row is: name, then "[21]" (how many you
    -- can make). Only when name + count + cost don't all fit is the name
    -- shortened, and only by as much as needed.
    local label, count = row.Label, row.Count
    row.fitpCostW = costW
    if label and not row.fitpHooked then
        row.fitpHooked = true
        row.fitpGameWidth = label:GetWidth()          -- what the game chose before we hooked in
        hooksecurefunc(label, "SetWidth", function(_, w)
            if row.fitpSizing or not w then return end
            row.fitpGameWidth = w
            FitLabel(row)
        end)
    end
    FitLabel(row)
    -- if the count is pinned to the row's right edge (not after the name),
    -- put the cost just left of it instead of on top of it
    if count and count.GetPoint then
        local _, rel = count:GetPoint(1)
        row.fitpHover:ClearAllPoints()
        if rel and rel ~= label then
            row.fitpHover:SetPoint("RIGHT", count, "LEFT", -4, 0)
        else
            row.fitpHover:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        end
    end
end

local function TagList(scrollBox)
    if scrollBox and scrollBox.ForEachFrame then
        pcall(scrollBox.ForEachFrame, scrollBox, function(row) pcall(TagRow, row) end)
    end
end

local function HookModernProfessions()
    local form = ProfessionsFrame and ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.SchematicForm
    if not form or modernLine or not (C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic) then return end
    -- under the reagents, above the "Track Recipe" box
    modernLine = CostLine(form, "BOTTOMLEFT", form, "BOTTOMLEFT", 28, 46)
    hooksecurefunc(form, "Init", function(_, recipeInfo)
        modernRecipe = recipeInfo and recipeInfo.recipeID
        if not form.fitpLearned then form.fitpLearned = true; pcall(LearnCrafts) end
        RefreshModern()
    end)
    ProfessionsFrame:HookScript("OnShow", function() form.fitpLearned = nil; wipe(profitCache) end)
    local list = ProfessionsFrame.CraftingPage.RecipeList
    local box = list and list.ScrollBox
    if box then
        if ScrollUtil and ScrollUtil.AddAcquiredFrameCallback then
            ScrollUtil.AddAcquiredFrameCallback(box, function(_, row) pcall(TagRow, row) end, list, true)
        end
        if box.Update then hooksecurefunc(box, "Update", function() TagList(box) end) end
        if box.FullUpdate then hooksecurefunc(box, "FullUpdate", function() TagList(box) end) end
    end
    ProfessionsFrame:HookScript("OnShow", RefreshModern)
end

H.TRADE_SKILL_UPDATE = function() RefreshTrade() end
H.TRADE_SKILL_LIST_UPDATE = function()
    pcall(LearnCrafts)
    wipe(profitCache)
    RefreshModern()
    local box = ProfessionsFrame and ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.RecipeList
        and ProfessionsFrame.CraftingPage.RecipeList.ScrollBox
    if box then TagList(box) end
end
H.CRAFT_UPDATE = function() RefreshCraft() end

function H.ADDON_LOADED(name)
    if name == "Blizzard_TradeSkillUI" or name == "Blizzard_CraftUI" then
        if DB then HookProfessions() end
        return
    end
    if name == "Blizzard_Professions" then
        if DB then HookModernProfessions() end
        return
    end
    if name ~= ADDON then return end
    ForeverItemTrackerPlusDB = ForeverItemTrackerPlusDB or {}
    DB = ForeverItemTrackerPlusDB
    -- keep the scan log across reloads: earlier lines first, then a marker
    if type(DB.scanLog) == "table" then
        local now = {}
        for i, line in ipairs(scanLog) do now[i] = line end
        for i = #scanLog, 1, -1 do scanLog[i] = nil end
        for _, line in ipairs(DB.scanLog) do scanLog[#scanLog + 1] = line end
        scanLog[#scanLog + 1] = date("%H:%M:%S") .. "  ---- reload ----"
        for _, line in ipairs(now) do scanLog[#scanLog + 1] = line end
        while #scanLog > 80 do table.remove(scanLog, 1) end
    end
    scanLog.lastText = nil
    DB.scanLog = scanLog
    DB.chars = DB.chars or {}
    DB.prices = DB.prices or {}
    DB.itemNames = DB.itemNames or {}   -- item name -> ID, from scans and recipes
    if DB.auto == nil then DB.auto = true end
end

-- The realm name. The game sometimes reports it as blank; then use the last
-- one seen, or (for older saves) the realm your characters are on.
local function CurrentRealm(name)
    local r = GetRealmName()
    if not r or r == "" then r = GetNormalizedRealmName and GetNormalizedRealmName() end
    if r and r ~= "" then DB.lastRealm = r; return r end
    if DB.lastRealm then return DB.lastRealm end
    -- your own character on exactly one realm, else the only realm there is
    local mine, mineMany, only, many = nil, false, nil, false
    for _, c in pairs(DB.chars) do
        if c.realm and c.realm ~= "" then
            if c.name == name then
                if mine and mine ~= c.realm then mineMany = true end
                mine = mine or c.realm
            end
            if only and only ~= c.realm then many = true end
            only = only or c.realm
        end
    end
    r = (not mineMany and mine) or (not many and only) or nil
    if r then DB.lastRealm = r end
    return r or ""
end

-- characters and prices saved while the realm name was blank go back under
-- the real realm (they're the newer copies)
local function RepairBlankRealm()
    if realm == "" then return end
    local chars, prices = {}, {}
    for k, c in pairs(DB.chars) do
        if c.realm == "" or c.realm == nil then chars[k] = c end
    end
    for k, p in pairs(DB.prices) do
        local faction = k:match("^%-(.+)$")
        if faction then prices[k] = faction end
    end
    for k, c in pairs(chars) do
        DB.chars[k] = nil
        c.realm = realm
        DB.chars[(c.name or "?") .. "-" .. realm] = c
    end
    for k, faction in pairs(prices) do
        local p = DB.prices[k]
        DB.prices[k] = nil
        local key = realm .. "-" .. faction
        local old = DB.prices[key]
        if not old or (p.time or 0) > (old.time or 0) then DB.prices[key] = p end
    end
end

function H.PLAYER_LOGIN()
    local name = UnitName("player")
    realm = CurrentRealm(name)
    RepairBlankRealm()
    me = name .. "-" .. realm
    priceKey = realm .. "-" .. (UnitFactionGroup("player") or "?")
    local c = Me()
    c.name, c.realm, c.class = name, realm, select(2, UnitClass("player"))
    c.gold = GetMoney()
    ScanBags()
    ScanEquip()

    HookTooltips()
    C_Timer.After(5, LearnPricedNames)
    C_Timer.After(65, LearnPricedNames)
    if HandleModifiedItemClick then hooksecurefunc("HandleModifiedItemClick", OnModifiedItemClick) end
    HookAllMoney()
    HookProfessions()                 -- (if the professions windows are already loaded)
    HookModernProfessions()

    for e in pairs(H) do
        if e ~= "ADDON_LOADED" and e ~= "PLAYER_LOGIN" then pcall(H.frame.RegisterEvent, H.frame, e) end
    end
end

H.BAG_UPDATE = QueueBags
H.PLAYERBANKSLOTS_CHANGED = QueueBags
function H.BANKFRAME_OPENED() bankOpen = true; CreateBankButtons(); QueueBags() end
function H.BANKFRAME_CLOSED() bankOpen = false end
function H.MERCHANT_SHOW() merchantOpen = true end
function H.MERCHANT_CLOSED() merchantOpen = false end
function H.PLAYER_EQUIPMENT_CHANGED() ScanEquip(); QueueBags() end
H.BAG_CONTAINER_UPDATE = QueueBags
function H.PLAYER_MONEY() Me().gold = GetMoney() end
H.MAIL_INBOX_UPDATE = ScanMail

local readyTicker
-- The game's Post buttons: grayed out while a scan runs (posting fails
-- then), back to normal when it ends. Only their enabled state is touched,
-- after the game sets it, so the game's own posting code is untouched.
local function SellFrames()
    local ah = AuctionHouseFrame
    return ah and ah.CommoditiesSellFrame, ah and ah.ItemSellFrame
end
local postHooked
local function HookPostButtons()
    if postHooked then return end
    postHooked = true
    for _, f in ipairs({ SellFrames() }) do
        if f and f.UpdatePostButtonState then
            hooksecurefunc(f, "UpdatePostButtonState", function(self)
                if scanning and self.PostButton then self.PostButton:SetEnabled(false) end
            end)
        end
    end
end
local function RefreshPostButtons()
    for _, f in ipairs({ SellFrames() }) do
        if f and f.PostButton then
            if scanning then
                f.PostButton:SetEnabled(false)
            elseif f.UpdatePostButtonState then
                pcall(f.UpdatePostButtonState, f)    -- let the game decide again
            end
        end
    end
end

-- "Full Scan" button under the auction house window, by the tabs.
-- Left-click scans now; right-click turns automatic scans on or off.
local scanButton
local function CreateScanButton()
    local ah = AuctionHouseFrame or AuctionFrame
    if scanButton or not ah then return end
    local b = CreateFrame("Button", nil, ah, "UIPanelButtonTemplate")
    scanButton = b
    b:SetSize(110, 22)
    b:SetPoint("TOPRIGHT", ah, "BOTTOMRIGHT", -6, -2)
    b:SetText("Full Scan")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local function tip(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Full Scan")
        local p = DB.prices[priceKey]
        GameTooltip:AddLine("Last scan: " .. (p and p.time and Ago(time() - p.time) or "never"), 1, 1, 1)
        local wait = p and p.asked and SERVER_COOLDOWN - (time() - p.asked)
        if wait and wait > 0 then
            GameTooltip:AddLine(string.format("Next scan possible in %d min.", math.ceil(wait / 60)), 1, 0.5, 0.25)
        end
        GameTooltip:AddLine("Automatic scans (at most once an hour): " .. (DB.auto and "|cff33ff33on|r" or "|cffff3333off|r"), 1, 1, 1)
        GameTooltip:AddLine("Left-click to scan now. Right-click to turn automatic scans on or off.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end
    -- the button's text counts down until the server allows the next scan
    -- (grayed while waiting; it stays clickable so right-click still works)
    local since, wasScanning = 1, false
    HookPostButtons()
    b:SetScript("OnUpdate", function(self, elapsed)
        if scanning ~= wasScanning then
            wasScanning = scanning
            RefreshPostButtons()
        end
        since = since + elapsed
        if since < 1 then return end
        since = 0
        local p = DB.prices[priceKey]
        local wait = p and p.asked and SERVER_COOLDOWN - (time() - p.asked)
        if scanning then
            self:SetText("Scanning...")
            self:GetFontString():SetTextColor(0.6, 0.6, 0.6)
        elseif wait and wait > 0 then
            self:SetText(wait >= 60 and string.format("Scan in %dm", math.ceil(wait / 60))
                or string.format("Scan in %ds", wait))
            self:GetFontString():SetTextColor(0.6, 0.6, 0.6)
        else
            self:SetText("Full Scan")
            self:GetFontString():SetTextColor(1, 0.82, 0)
        end
    end)
    b:SetScript("OnEnter", tip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            DB.auto = not DB.auto
            Msg("automatic scanning %s.", DB.auto and "on" or "off")
        else
            TryScan(true)
        end
        if GameTooltip:IsOwned(self) then tip(self) end
    end)
end

function H.AUCTION_HOUSE_SHOW()
    ahOpen = true
    CreateScanButton()
    Log("auction house opened")
    C_Timer.After(1, function() TryScan() end)
    if ticker then ticker:Cancel() end
    ticker = C_Timer.NewTicker(30, function() TryScan() end)
    -- note in the scan log whenever the auction house goes busy / ready
    if readyTicker then readyTicker:Cancel() end
    local ready = C_AuctionHouse and C_AuctionHouse.IsThrottledMessageSystemReady
    if ready then
        local last = ready()
        Log("auction house ready for searches: %s", tostring(last))
        readyTicker = C_Timer.NewTicker(1, function()
            local now = ready()
            if now ~= last then
                Log("auction house is now %s", now and "ready for searches" or "busy")
                last = now
            end
        end)
    end
end
function H.AUCTION_HOUSE_CLOSED()
    if scanning then Log("auction house closed mid-scan (waiting=%s)", tostring(awaiting)) end
    ahOpen, awaiting, scanning = false, false, false
    if ticker then ticker:Cancel(); ticker = nil end
    if readyTicker then readyTicker:Cancel(); readyTicker = nil end
    StopWaiting()
    if bar then bar:Hide() end
end
H.AUCTION_ITEM_LIST_UPDATE = function() OnScanData("AUCTION_ITEM_LIST_UPDATE") end
-- the auction house's request queue: searches wait while it's busy
H.AUCTION_HOUSE_THROTTLED_SYSTEM_READY = function() Log("auction house ready for requests again") end
H.AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED = function() Log("auction house dropped a request (busy)") end
H.AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED = function() Log("auction house queued a request (busy)") end
H.AUCTION_HOUSE_THROTTLED_MESSAGE_SENT = function() Log("auction house sent a queued request") end
H.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED = function()
    local r = C_AuctionHouse.GetBrowseResults and C_AuctionHouse.GetBrowseResults()
    Log("search results arrived: %s", r and #r or "?")
end
H.AUCTION_HOUSE_BROWSE_FAILURE = function() Log("a search failed") end
H.AUCTION_HOUSE_NEW_RESULTS_RECEIVED = function() Log("new search results received") end
H.REPLICATE_ITEM_LIST_UPDATE = function() OnScanData("REPLICATE_ITEM_LIST_UPDATE") end

local f = CreateFrame("Frame")
H.frame = f
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(_, e, ...)
    local fn = H[e]
    if type(fn) == "function" then fn(...) end
end)

---------------------------------------------------------------------------
-- /fitp, /itemtracker
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Talking to a banker opens your bank straight away (hold Shift to see
-- the banker's dialogue instead).
---------------------------------------------------------------------------
do
    local BANK_ICON = 132050                      -- the gossip "bank" icon
    local f = CreateFrame("Frame")
    f:RegisterEvent("GOSSIP_SHOW")
    f:SetScript("OnEvent", function()
        if IsShiftKeyDown() then return end
        if C_GossipInfo and C_GossipInfo.GetOptions then
            for _, o in ipairs(C_GossipInfo.GetOptions() or {}) do
                local icon = o.icon or o.overrideIconID
                if icon == BANK_ICON or icon == "Interface\\GossipFrame\\BankerGossipIcon"
                    or (o.name and o.name:lower():find("deposit box")) then
                    C_GossipInfo.SelectOption(o.gossipOptionID)
                    return
                end
            end
        elseif GetGossipOptions and SelectGossipOption then
            local opts = { GetGossipOptions() }
            for i = 1, #opts, 2 do
                if opts[i + 1] == "banker" then SelectGossipOption((i + 1) / 2); return end
            end
        end
    end)
end

---------------------------------------------------------------------------
-- Sort bags by value: a button on your bags puts the most valuable stacks
-- first. A stack's value is its count times the higher of its AH price (last
-- scan) and vendor price. Out of combat only; items are swapped one pair at
-- a time, waiting for each move to finish.
---------------------------------------------------------------------------
do
    local S = { running = false }

    local function Slots()
        local list = {}
        for bag = 0, (NUM_BAG_SLOTS or 4) do
            -- only ordinary bags (profession bags hold only their own kind)
            local family = bag == 0 and 0 or select(2, C_Container.GetContainerNumFreeSlots(bag))
            if family == 0 then
                for slot = 1, C_Container.GetContainerNumSlots(bag) do list[#list + 1] = { bag, slot } end
            end
        end
        return list
    end

    local function Value(info)
        if not info then return -1 end
        local p = DB.prices[priceKey]
        local ah = p and p.items and p.items[info.itemID] or 0
        local vendor = ItemInfo and select(11, ItemInfo(info.itemID)) or 0
        return math.max(ah or 0, vendor or 0) * (info.stackCount or 1)
    end

    -- what should come first: higher value, then by item and bigger stacks
    local function Key(info)
        if not info then return { -1, 0, 0 } end
        return { Value(info), info.itemID or 0, info.stackCount or 1 }
    end
    local function Before(a, b)
        if a[1] ~= b[1] then return a[1] > b[1] end
        if a[2] ~= b[2] then return a[2] < b[2] end
        return a[3] > b[3]
    end
    local function Same(a, b) return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] end

    -- Each tick: work out the whole sorted order, then make every swap whose
    -- two slots aren't still busy from an earlier move, all at once.
    local function Step()
        if InCombatLockdown() then S.Stop("stopped: you entered combat"); return end
        if GetCursorInfo() then return end
        local slots = Slots()
        local keys, locked = {}, {}
        for i, s in ipairs(slots) do
            local info = C_Container.GetContainerItemInfo(s[1], s[2])
            keys[i] = Key(info)
            locked[i] = info and info.isLocked
        end
        local touched, made, waiting = {}, 0, false
        for t = 1, #slots do
            local best = t
            for i = t + 1, #slots do
                if Before(keys[i], keys[best]) then best = i end
            end
            if best ~= t and not Same(keys[best], keys[t]) then
                if locked[t] or locked[best] or touched[t] or touched[best] then
                    waiting = true
                else
                    C_Container.PickupContainerItem(slots[best][1], slots[best][2])
                    C_Container.PickupContainerItem(slots[t][1], slots[t][2])
                    touched[t], touched[best] = true, true
                    made = made + 1
                end
                keys[t], keys[best] = keys[best], keys[t]
            end
        end
        S.moves = S.moves + made
        if S.moves > 1000 then S.Stop("stopped after 1000 moves"); return end
        if made == 0 and not waiting then S.Stop() end
    end

    function S.Stop(why)
        if S.ticker then S.ticker:Cancel(); S.ticker = nil end
        S.running = false
        if why then Msg("bag sort %s.", why) end
    end

    function S.Start()
        if S.running then return end
        if InCombatLockdown() then Msg("can't sort bags in combat."); return end
        S.running, S.moves = true, 0
        S.ticker = C_Timer.NewTicker(0.05, Step)
    end

    local function AddButton(frame)
        if not frame or frame.fitpSort then return end
        local b = CreateFrame("Button", nil, frame)
        frame.fitpSort = b
        -- the same size as the game's Clean Up button, styled like an action button
        local cleanup = BagItemAutoSortButton
        local size = (cleanup and cleanup:GetParent() == frame and math.floor(cleanup:GetHeight() + 0.5)) or 24
        b:SetSize(size, size)
        if cleanup and cleanup:GetParent() == frame then
            b:SetPoint("RIGHT", cleanup, "LEFT", -5, 0)
        else
            b:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -32, -32)
        end
        b:SetFrameLevel(frame:GetFrameLevel() + 10)
        local icon = b:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", -1, 1)
        icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_17")
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local function Atlas(tex, name)
            return tex.SetAtlas and pcall(tex.SetAtlas, tex, name) and tex:GetAtlas() == name
        end
        local mask = b:CreateMaskTexture()
        if Atlas(mask, "UI-HUD-ActionBar-IconFrame-Mask") then
            mask:SetAllPoints(icon)
            icon:AddMaskTexture(mask)
        end
        local border = b:CreateTexture(nil, "OVERLAY")
        border:SetPoint("TOPLEFT", -1, 1)
        border:SetPoint("BOTTOMRIGHT", 1, -1)
        if not Atlas(border, "UI-HUD-ActionBar-IconFrame") then
            border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
            border:SetPoint("TOPLEFT", -size * 0.45, size * 0.45)
            border:SetPoint("BOTTOMRIGHT", size * 0.45, -size * 0.45)
        end
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(border)
        if not Atlas(hl, "UI-HUD-ActionBar-IconFrame-Mouseover") then
            hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
            hl:SetAllPoints(icon)
            hl:SetBlendMode("ADD")
        end
        b:SetScript("OnMouseDown", function() icon:SetVertexColor(0.7, 0.7, 0.7) end)
        b:SetScript("OnMouseUp", function() icon:SetVertexColor(1, 1, 1) end)
        b:SetScript("OnClick", S.Start)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine("Sort by value")
            GameTooltip:AddLine("Most valuable stacks first: count x the higher of AH and vendor price.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function()
        for _, name in ipairs({ "ContainerFrameCombinedBags", "ContainerFrame1" }) do
            local fr = _G[name]
            if fr then
                if fr:IsShown() then AddButton(fr) end
                fr:HookScript("OnShow", function(self) AddButton(self) end)
            end
        end
    end)
end

local LedgerRefresh
---------------------------------------------------------------------------
-- Ledger: a list of every money transaction on every character, like a
-- spreadsheet: when, who, source, what it was, amount. Each change in your
-- gold is filed under whatever you were doing at that moment (selling to a
-- vendor, taking mail, a flight...) with the item, quest, player or place.
-- Opened from the minimap button (or /fitp ledger).
---------------------------------------------------------------------------
local OpenLedger
do
    local MAX_ROWS = 10000              -- oldest are dropped past this

    local open = {}                     -- game windows open right now
    local expectCat, expectDetail, expectUntil = nil, nil, 0
    local windowDetail = {}             -- detail for an open window (trade partner, quest...)
    local lastMoney

    -- a money change in the next few seconds belongs to this
    local function Expect(cat, detail)
        expectCat, expectDetail, expectUntil = cat, detail, GetTime() + 3
    end

    local ORDER = { "trade", "loot", "quest", "ah", "merchant", "train", "taxi", "guild", "mail" }
    local SOURCE = { trade = "Trade", loot = "Loot", quest = "Quest", ah = "Auction house",
        merchant = "Vendor", train = "Training", taxi = "Flight", guild = "Guild bank", mail = "Mail",
        repair = "Repair", other = "Other" }

    -- things that only ever cost money: a gain in the same moment (selling
    -- right after repairing, say) isn't theirs
    local SPEND_ONLY = { repair = true, taxi = true, train = true }
    -- ...and repairs and flights are one payment each
    local ONE_PAYMENT = { repair = true, taxi = true }

    local function Context(delta)
        if expectCat and GetTime() < expectUntil and not (SPEND_ONLY[expectCat] and delta > 0) then
            local cat, detail = expectCat, expectDetail
            if ONE_PAYMENT[cat] then expectCat = nil end
            return cat, detail
        end
        for _, w in ipairs(ORDER) do
            if open[w] then return w, windowDetail[w] end
        end
        -- gold that arrives with no window open is your share of group loot
        return "loot", nil
    end

    -- Loot and Other are many small amounts: one row per character per day,
    -- added up, with how many times
    local ROLLUP = { Loot = true, Other = true }
    local function Day(t) return date("%Y-%m-%d", t) end
    local function RollupText(source, n)
        if source == "Loot" then return n == 1 and "looted once" or ("looted " .. n .. " times") end
        return n == 1 and "1 change" or (n .. " changes")
    end
    local function AddToRollup(source, who, t, delta, n)
        local today = Day(t)
        for i = #DB.ledger, 1, -1 do
            local r = DB.ledger[i]
            if Day(r[1]) ~= today then break end
            if r[2] == who and r[3] == source then
                r[1], r[5], r[7] = t, r[5] + delta, (r[7] or 1) + n
                r[4] = RollupText(source, r[7])
                return true
            end
        end
    end

    local function Record(delta)
        DB.ledger = DB.ledger or {}
        local cat, detail = Context(delta)
        local c = Me()
        local source = SOURCE[cat] or cat
        if ROLLUP[source] then
            if not AddToRollup(source, me, time(), delta, 1) then
                table.insert(DB.ledger, { time(), me, source, RollupText(source, 1), delta, c.class, 1 })
            end
            if LedgerRefresh then LedgerRefresh() end
            return
        end
        table.insert(DB.ledger, { time(), me, source, detail or "", delta, c.class })
        while #DB.ledger > MAX_ROWS do table.remove(DB.ledger, 1) end
        if LedgerRefresh then LedgerRefresh() end
    end

    local function Name(link) return link and (link:match("%[(.-)%]") or link) end

    local ev = CreateFrame("Frame")
    local WINDOWS = {
        MERCHANT_SHOW = { "merchant", true }, MERCHANT_CLOSED = { "merchant", false },
        AUCTION_HOUSE_SHOW = { "ah", true }, AUCTION_HOUSE_CLOSED = { "ah", false },
        MAIL_SHOW = { "mail", true }, MAIL_CLOSED = { "mail", false },
        TRADE_SHOW = { "trade", true }, TRADE_CLOSED = { "trade", false },
        TRAINER_SHOW = { "train", true }, TRAINER_CLOSED = { "train", false },
        TAXIMAP_OPENED = { "taxi", true }, TAXIMAP_CLOSED = { "taxi", false },
        GUILDBANKFRAME_OPENED = { "guild", true }, GUILDBANKFRAME_CLOSED = { "guild", false },
        LOOT_OPENED = { "loot", true }, LOOT_CLOSED = { "loot", false },
        QUEST_COMPLETE = { "quest", true }, QUEST_FINISHED = { "quest", false },
    }
    local INTERACTION = {}
    if Enum and Enum.PlayerInteractionType then
        local T = Enum.PlayerInteractionType
        for name, w in pairs({ Merchant = "merchant", Trainer = "train", TaxiNode = "taxi",
            MailInfo = "mail", GuildBanker = "guild", Auctioneer = "ah" }) do
            if T[name] then INTERACTION[T[name]] = w end
        end
    end
    local AFTER = { TRADE_CLOSED = "trade", LOOT_CLOSED = "loot", QUEST_FINISHED = "quest" }

    local function NPCName() return UnitName("npc") or UnitName("target") end

    ev:SetScript("OnEvent", function(_, e, arg)
        if e == "PLAYER_ENTERING_WORLD" then
            lastMoney = GetMoney()
        elseif e == "PLAYER_MONEY" then
            local now = GetMoney()
            if lastMoney and DB and me and now ~= lastMoney then Record(now - lastMoney) end
            lastMoney = now
        elseif e == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
            local w = INTERACTION[arg]
            if w then open[w] = true; windowDetail[w] = (w == "merchant" or w == "train") and NPCName() or nil end
        elseif e == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
            if INTERACTION[arg] then open[INTERACTION[arg]] = false end
        elseif e == "QUEST_TURNED_IN" then
            local title = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(arg)
            Expect("quest", title or windowDetail.quest)
        elseif e == "CHAT_MSG_MONEY" then
            Expect("loot", windowDetail.loot)
        elseif WINDOWS[e] then
            local w, isOpen = WINDOWS[e][1], WINDOWS[e][2]
            if isOpen then
                if w == "trade" then windowDetail.trade = "with " .. (UnitName("NPC") or "?")
                elseif w == "quest" then windowDetail.quest = GetTitleText and GetTitleText()
                elseif w == "loot" then windowDetail.loot = UnitExists("target") and UnitIsDead("target") and UnitName("target") or nil
                elseif w == "merchant" or w == "train" then windowDetail[w] = NPCName() end
            end
            open[w] = isOpen
            if AFTER[e] then Expect(AFTER[e], windowDetail[AFTER[e]]) end
        end
    end)
    for e in pairs(WINDOWS) do pcall(ev.RegisterEvent, ev, e) end
    for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_MONEY", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
        "PLAYER_INTERACTION_MANAGER_FRAME_HIDE", "QUEST_TURNED_IN", "CHAT_MSG_MONEY" }) do
        pcall(ev.RegisterEvent, ev, e)
    end

    -- what exactly the money was for
    local function Hook(tbl, name, fn)
        if tbl and tbl[name] then hooksecurefunc(tbl, name, fn) end
    end
    local function Count(n) return (n and n > 1) and (" x" .. n) or "" end
    Hook(_G, "RepairAllItems", function(guild) Expect("repair", guild and "all (guild bank)" or "all items") end)
    local function RepairOne()
        if InRepairMode and InRepairMode() then Expect("repair", "one item") end
    end
    Hook(_G, "PickupInventoryItem", RepairOne)
    -- selling: right-clicking an item at a vendor
    local function Sold(bag, slot)
        if not open.merchant or not C_Container then return end
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info and info.hyperlink then
            Expect("merchant", "sold " .. Name(info.hyperlink) .. Count(info.stackCount))
        end
    end
    Hook(C_Container, "UseContainerItem", Sold)
    Hook(C_Container, "PickupContainerItem", function(bag, slot)
        RepairOne()
        if open.merchant and not (InRepairMode and InRepairMode()) then Sold(bag, slot) end
    end)
    Hook(_G, "BuyMerchantItem", function(i, n)
        Expect("merchant", "bought " .. (Name(GetMerchantItemLink and GetMerchantItemLink(i)) or "item") .. Count(n))
    end)
    Hook(_G, "BuybackItem", function(i)
        Expect("merchant", "bought back " .. (Name(GetBuybackItemLink and GetBuybackItemLink(i)) or "item"))
    end)
    Hook(_G, "BuyTrainerService", function(i)
        local name = GetTrainerServiceInfo and GetTrainerServiceInfo(i)
        Expect("train", name)
    end)
    Hook(_G, "TakeTaxiNode", function(i) Expect("taxi", "to " .. (TaxiNodeName and TaxiNodeName(i) or "?")) end)
    -- mail: auction house sales and refunds, or money from a player
    local function MailMoney(i)
        local kind, itemName, player = nil, nil, nil
        if GetInboxInvoiceInfo then kind, itemName, player = GetInboxInvoiceInfo(i) end
        if kind then
            local what = kind == "seller" and "sold " or kind == "buyer" and "bought " or (kind .. " ")
            Expect("ah", what .. (itemName or "?") .. (player and player ~= "" and (" (" .. player .. ")") or ""))
        else
            local _, _, sender, subject = GetInboxHeaderInfo(i)
            Expect("mail", (sender or "?") .. (subject and subject ~= "" and (": " .. subject) or ""))
        end
    end
    Hook(_G, "TakeInboxMoney", MailMoney)
    Hook(_G, "AutoLootMailItem", MailMoney)
    Hook(_G, "SendMail", function(to) Expect("mail", "postage to " .. (to or "?")) end)
    -- auction house: buying and posting
    if C_AuctionHouse then
        Hook(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(id, n)
            Expect("ah", "bought " .. (C_Item.GetItemNameByID(id) or "item") .. Count(n))
        end)
        -- gear and other one-off auctions: look the auction up for its item
        Hook(C_AuctionHouse, "PlaceBid", function(auctionID, amount)
            local info = C_AuctionHouse.GetAuctionInfoByID and C_AuctionHouse.GetAuctionInfoByID(auctionID)
            local name = info and info.itemLink and Name(info.itemLink)
            if not name and info and info.itemKey and C_Item.GetItemNameByID then
                name = C_Item.GetItemNameByID(info.itemKey.itemID)
            end
            local bid = info and info.buyoutAmount and amount and amount < info.buyoutAmount
            Expect("ah", (bid and "bid on " or "bought ") .. (name or "item")
                .. ((info and info.quantity and info.quantity > 1) and (" x" .. info.quantity) or ""))
        end)
        Hook(C_AuctionHouse, "PostCommodity", function(loc, _, n)
            local link = loc and C_Item.GetItemLink and C_Item.GetItemLink(loc)
            Expect("ah", "deposit " .. (Name(link) or "item") .. Count(n))
        end)
        Hook(C_AuctionHouse, "PostItem", function(loc)
            local link = loc and C_Item.GetItemLink and C_Item.GetItemLink(loc)
            Expect("ah", "deposit " .. (Name(link) or "item"))
        end)
    end

    -----------------------------------------------------------------------
    -- The window: a sortable table
    -----------------------------------------------------------------------
    local win
    local who = nil                     -- character key, or nil for everyone
    local sortCol, sortDesc = 1, true
    local offset = 0
    local ROW_H, VISIBLE = 19, 20
    local TABLE_W = 780
    local COLS = {                       -- title, width, field, align
        { "Date", 130, 1, "LEFT" }, { "Character", 130, 2, "LEFT" }, { "Source", 110, 3, "LEFT" },
        { "Details", 265, 4, "LEFT" }, { "Amount", 145, 5, "RIGHT" },
    }
    -- the first view: one row per source; click one for its transactions
    local SUMMARY = {
        { "Source", 250, nil, "LEFT" }, { "Transactions", 115, nil, "RIGHT" }, { "Earned", 135, nil, "RIGHT" },
        { "Spent", 135, nil, "RIGHT" }, { "Net", 145, nil, "RIGHT" },
    }
    local source = nil                   -- nil: the list of sources
    local sumCol, sumDesc = nil, true    -- sources list sort (nil: busiest first)

    -- time ranges for the dropdown; each gives (from, to) in seconds
    local function Midnight(daysAgo)
        local t = date("*t")
        t.hour, t.min, t.sec = 0, 0, 0
        return time(t) - (daysAgo or 0) * 86400
    end
    local RANGES = {
        { "Today", function() return Midnight(0), math.huge end },
        { "Yesterday", function() return Midnight(1), Midnight(0) end },
        { "Last 7 days", function() return Midnight(6), math.huge end },
        { "Last 30 days", function() return Midnight(29), math.huge end },
        { "All time", function() return 0, math.huge end },
    }
    local range = 1

    local function Filtered()
        local list = {}
        local from, to = RANGES[range][2]()
        for _, r in ipairs(DB.ledger or {}) do
            if (not who or r[2] == who) and r[1] >= from and r[1] < to
                and (not source or r[3] == source) then
                list[#list + 1] = r
            end
        end
        local f = COLS[sortCol][3]
        table.sort(list, function(a, b)
            local x, y = a[f], b[f]
            if x == y then x, y = a[1], b[1] end
            if sortDesc then return x > y else return x < y end
        end)
        return list
    end

    local function CharText(r)
        local c = DB.chars[r[2]]
        if c then return ColoredName(c) end
        return (r[2] or "?"):match("^(.-)%-") or r[2]
    end

    local function AmountText(n)
        if n >= 0 then return "|cff33ff33+|r" .. Coin(n) end
        return "|cffff4444-|r" .. Coin(-n)
    end

    function LedgerRefresh()
        if not (win and win:IsShown()) then return end
        win.who:SetText(who and ColoredName(DB.chars[who]) or "All characters")
        win.rangeButton:SetText(RANGES[range][1] .. "  v")
        local list = Filtered()
        local cols = source and COLS or SUMMARY
        win.Layout(cols)
        win.back:SetShown(source ~= nil)
        win.title:SetText(source and ("Ledger: " .. source) or "Ledger")
        local shown
        if source then
            shown = list
        else
            -- add up per source, busiest first
            local by, order = {}, {}
            for _, r in ipairs(list) do
                local e = by[r[3]]
                if not e then e = { r[3], 0, 0, 0 }; by[r[3]] = e; order[#order + 1] = e end
                e[2] = e[2] + (r[7] or 1)
                if r[5] > 0 then e[3] = e[3] + r[5] else e[4] = e[4] - r[5] end
            end
            for _, e in ipairs(order) do e[5] = e[3] - e[4] end
            table.sort(order, function(a, b)
                if not sumCol then return a[3] + a[4] > b[3] + b[4] end
                local x, y = a[sumCol], b[sumCol]
                if x == y then return a[1] < b[1] end
                if sumDesc then return x > y else return x < y end
            end)
            shown = order
        end
        offset = math.max(0, math.min(offset, #shown - VISIBLE))
        for i, row in ipairs(win.rows) do
            local r = shown[offset + i]
            row.key = nil
            for j = 1, #row.money do row.money[j]:Hide(); row.cells[j]:Show() end
            local function Money(j, amount, signed)
                row.cells[j]:Hide()
                row.money[j]:Set(amount, signed)
            end
            if r and source then
                row.cells[1]:SetText(date("%m/%d %H:%M", r[1]))
                row.cells[2]:SetText(CharText(r))
                row.cells[3]:SetText(r[3])
                row.cells[4]:SetText(r[4])
                Money(5, r[5], true)
                row:Show()
            elseif r then
                row.key = r[1]
                row.cells[1]:SetText(r[1])
                row.cells[2]:SetText(r[2])
                if r[3] > 0 then Money(3, r[3]) else row.cells[3]:SetText("|cff808080-|r") end
                if r[4] > 0 then Money(4, r[4]) else row.cells[4]:SetText("|cff808080-|r") end
                Money(5, r[3] - r[4], true)
                row:Show()
            else
                row:Hide()
            end
        end
        if #shown == 0 then
            win.empty:SetText("No transactions for " .. RANGES[range][1]:lower() .. ".")
        end
        win.empty:SetShown(#shown == 0)
        local earned, spent = 0, 0
        for _, r in ipairs(list) do
            if r[5] > 0 then earned = earned + r[5] else spent = spent - r[5] end
        end
        local net = earned - spent
        win.foot:SetText(string.format("%d transactions   Earned %s   Spent %s   Net %s",
            #list, Coin(earned), Coin(spent), (net >= 0 and "|cff33ff33+|r" or "|cffff4444-|r") .. Coin(math.abs(net))))
        win.pos:SetText(#shown > VISIBLE and string.format("%d-%d of %d", offset + 1,
            math.min(offset + VISIBLE, #shown), #shown) or "")
        for i, h in ipairs(win.heads) do
            local active = (source and i == sortCol) or (not source and i == sumCol)
            local desc = source and sortDesc or sumDesc
            h.text:SetText(cols[i][1] .. (active and (desc and " v" or " ^") or ""))
        end
        win.tip:SetText(source and "Scroll to move (Shift: a page). Click a column to sort."
            or "Click a source to see its transactions. Click a column to sort.")
    end

    -- A money cell: gold, silver and copper each in their own right-aligned
    -- slot, so amounts line up in columns down the table.
    local ICON = {
        g = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t",
        s = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t",
        c = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t",
    }
    local SLOT = 36                      -- width of the silver and copper slots
    local function MoneyCell(parent)
        local m = CreateFrame("Frame", nil, parent)
        m:SetHeight(ROW_H)
        local function fs()
            local f = m:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            f:SetJustifyH("RIGHT"); f:SetWordWrap(false)
            return f
        end
        m.c = fs(); m.c:SetPoint("RIGHT", 0, 0); m.c:SetWidth(SLOT)
        m.s = fs(); m.s:SetPoint("RIGHT", m.c, "LEFT", 0, 0); m.s:SetWidth(SLOT)
        m.g = fs(); m.g:SetPoint("RIGHT", m.s, "LEFT", 0, 0)
        m.sign = fs(); m.sign:SetPoint("RIGHT", m.g, "LEFT", -2, 0); m.sign:SetWidth(10)
        function m:Set(amount, signed)
            local n = math.abs(amount)
            local g, sv, c = math.floor(n / 10000), math.floor(n / 100) % 100, n % 100
            self.g:SetText(g > 0 and (g .. ICON.g) or "")
            self.s:SetText((g > 0 or sv > 0) and (sv .. ICON.s) or "")
            self.c:SetText(c .. ICON.c)
            if signed then
                self.sign:SetText(amount >= 0 and "|cff33ff33+|r" or "|cffff4444-|r")
            else
                self.sign:SetText("")
            end
            self:Show()
        end
        return m
    end

    local function CSV()
        local out = { "Date,Character,Source,Details,Amount (copper)" }
        local function q(v)
            local text = tostring(v):gsub('"', '""')
            return '"' .. text .. '"'
        end
        for _, r in ipairs(Filtered()) do
            out[#out + 1] = table.concat({ q(date("%Y-%m-%d %H:%M:%S", r[1])), q(r[2]), q(r[3]), q(r[4]), r[5] }, ",")
        end
        return table.concat(out, "\n")
    end

    local function Build()
        local W = 20 + TABLE_W + 20
        win = CreateFrame("Frame", "ForeverItemTrackerLedger", UIParent, "BasicFrameTemplateWithInset")
        win:SetSize(W, 30 + 40 + 20 + VISIBLE * ROW_H + 50)
        win:SetPoint("CENTER")
        win:SetFrameStrata("DIALOG")
        win:SetMovable(true)
        win:EnableMouse(true)
        win:RegisterForDrag("LeftButton")
        win:SetScript("OnDragStart", win.StartMoving)
        win:SetScript("OnDragStop", win.StopMovingOrSizing)
        win:SetClampedToScreen(true)
        tinsert(UISpecialFrames, "ForeverItemTrackerLedger")
        local title = win.TitleText or win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        if not win.TitleText then title:SetPoint("TOP", 0, -5) end
        title:SetText("Ledger")
        win.title = title

        -- character filter
        local prev = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        prev:SetSize(24, 22); prev:SetPoint("TOPLEFT", 14, -32); prev:SetText("<")
        win.who = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        win.who:SetPoint("LEFT", prev, "RIGHT", 8, 0)
        win.who:SetWidth(180); win.who:SetJustifyH("LEFT")
        local nxt = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        nxt:SetSize(24, 22); nxt:SetPoint("LEFT", win.who, "RIGHT", 4, 0); nxt:SetText(">")
        local function Step(dir)
            local list = SortedChars()
            local pos = 0
            for i, k in ipairs(list) do if k == who then pos = i end end
            pos = (pos + dir) % (#list + 1)
            who = pos > 0 and list[pos] or nil
            offset = 0
            LedgerRefresh()
        end
        prev:SetScript("OnClick", function() Step(-1) end)
        nxt:SetScript("OnClick", function() Step(1) end)

        -- copy as CSV (for a real spreadsheet)
        local export = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        export:SetSize(110, 22); export:SetPoint("TOPRIGHT", -14, -32); export:SetText("Copy as CSV")

        -- time range: a button that opens a small list of ranges. (The game's
        -- own dropdown menus share their menu system with the right-click
        -- unit menu, and using them from an addon gets Set Focus / Target
        -- Marker Icon there blocked, so this one is home-made.)
        local function SetRange(i) range = i; offset = 0; LedgerRefresh() end
        local rb = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        rb:SetSize(130, 22)
        rb:SetPoint("RIGHT", export, "LEFT", -10, 0)
        win.rangeButton = rb
        local list = CreateFrame("Frame", nil, rb, "TooltipBackdropTemplate")
        list:SetPoint("TOPLEFT", rb, "BOTTOMLEFT", 0, -2)
        list:SetSize(130, #RANGES * 20 + 10)
        list:SetFrameStrata("FULLSCREEN_DIALOG")
        list:Hide()
        if not list.SetBackdrop then
            local bg = list:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints(); bg:SetColorTexture(0.05, 0.05, 0.08, 0.95)
        end
        for i, r in ipairs(RANGES) do
            local o = CreateFrame("Button", nil, list)
            o:SetSize(120, 20)
            o:SetPoint("TOPLEFT", 5, -5 - (i - 1) * 20)
            o:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            o.text = o:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            o.text:SetPoint("LEFT", 6, 0)
            o.text:SetText(r[1])
            o:SetScript("OnClick", function() list:Hide(); SetRange(i) end)
        end
        rb:SetScript("OnClick", function() list:SetShown(not list:IsShown()) end)
        win:HookScript("OnHide", function() list:Hide() end)
        local box = CreateFrame("Frame", nil, win, "BasicFrameTemplateWithInset")
        box:SetAllPoints(); box:SetFrameLevel(win:GetFrameLevel() + 20); box:Hide()
        local bs = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
        bs:SetPoint("TOPLEFT", 14, -50); bs:SetPoint("BOTTOMRIGHT", -34, 14)
        local eb = CreateFrame("EditBox", nil, bs)
        eb:SetMultiLine(true); eb:SetFontObject(ChatFontNormal or GameFontHighlight)
        eb:SetWidth(W - 60); eb:SetAutoFocus(false)
        eb:SetScript("OnEscapePressed", function() box:Hide() end)
        bs:SetScrollChild(eb)
        local hint = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        hint:SetPoint("TOPLEFT", 14, -30)
        hint:SetText("Press Ctrl+C to copy, then paste into a spreadsheet. Escape to go back.")
        export:SetScript("OnClick", function()
            box:Show(); eb:SetText(CSV()); eb:SetFocus(); eb:HighlightText()
        end)

        -- column headers (click to sort)
        win.heads = {}
        local x = 20
        for i, c in ipairs(COLS) do
            local h = CreateFrame("Button", nil, win)
            h:SetSize(c[2], 18)
            h:SetPoint("TOPLEFT", x, -64)
            h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            h.text:SetAllPoints(); h.text:SetJustifyH(c[4])
            h:SetScript("OnClick", function()
                if not source then
                    -- sources list: name A-Z first, numbers biggest first
                    if sumCol == i then sumDesc = not sumDesc else sumCol, sumDesc = i, i ~= 1 end
                    offset = 0
                    LedgerRefresh()
                    return
                end
                if sortCol == i then sortDesc = not sortDesc else sortCol, sortDesc = i, (i == 1 or i == 5) end
                offset = 0
                LedgerRefresh()
            end)
            win.heads[i] = h
            x = x + c[2]
        end
        local line = win:CreateTexture(nil, "ARTWORK")
        line:SetColorTexture(1, 1, 1, 0.15)
        line:SetPoint("TOPLEFT", 18, -83); line:SetSize(TABLE_W + 4, 1)

        -- rows
        win.rows = {}
        for i = 1, VISIBLE do
            local row = CreateFrame("Button", nil, win)
            row:SetSize(TABLE_W, ROW_H)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            row:SetScript("OnClick", function(self)
                if self.key then source = self.key; offset = 0; LedgerRefresh() end
            end)
            row:SetPoint("TOPLEFT", 20, -86 - (i - 1) * ROW_H)
            if i % 2 == 0 then
                local bg = row:CreateTexture(nil, "BACKGROUND")
                bg:SetAllPoints(); bg:SetColorTexture(1, 1, 1, 0.04)
            end
            row.cells = {}
            local cx = 0
            for j, c in ipairs(COLS) do
                local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                fs:SetPoint("LEFT", cx + 2, 0); fs:SetWidth(c[2] - 6); fs:SetJustifyH(c[4])
                fs:SetWordWrap(false)
                row.cells[j] = fs
                cx = cx + c[2]
            end
            row.money = {}
            for j = 1, #COLS do
                row.money[j] = MoneyCell(row)
                row.money[j]:Hide()
            end
            win.rows[i] = row
        end
        -- place headers and cells for a set of columns
        function win.Layout(cols)
            local hx = 20
            for i, c in ipairs(cols) do
                local h = win.heads[i]
                h:ClearAllPoints(); h:SetPoint("TOPLEFT", hx, -64); h:SetSize(c[2], 18)
                h.text:SetJustifyH(c[4])
                hx = hx + c[2]
            end
            for _, row in ipairs(win.rows) do
                local cx = 0
                for j, c in ipairs(cols) do
                    local fs = row.cells[j]
                    fs:ClearAllPoints(); fs:SetPoint("LEFT", cx + 2, 0)
                    fs:SetWidth(c[2] - 6); fs:SetJustifyH(c[4])
                    local m = row.money[j]
                    m:ClearAllPoints(); m:SetPoint("LEFT", cx, 0); m:SetWidth(c[2] - 4)
                    m.g:SetWidth(math.max(20, c[2] - 4 - 2 * SLOT - 12))
                    cx = cx + c[2]
                end
            end
        end
        win.empty = win:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        win.empty:SetPoint("TOP", 0, -110)
        -- back to the list of sources
        win.back = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        win.back:SetSize(120, 22)
        win.back:SetPoint("LEFT", nxt, "RIGHT", 12, 0)
        win.back:SetText("< All sources")
        win.back:SetScript("OnClick", function() source = nil; offset = 0; LedgerRefresh() end)
        win:EnableMouseWheel(true)
        win:SetScript("OnMouseWheel", function(_, d)
            offset = offset - d * (IsShiftKeyDown() and VISIBLE or 3)
            if offset < 0 then offset = 0 end
            LedgerRefresh()
        end)

        win.pos = win:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        win.pos:SetPoint("BOTTOMRIGHT", -20, 30)
        win.foot = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        win.foot:SetPoint("BOTTOMLEFT", 20, 12)
        -- hover the totals: earned and spent by source
        local hover = CreateFrame("Frame", nil, win)
        hover:SetPoint("TOPLEFT", win.foot, "TOPLEFT", -2, 3)
        hover:SetPoint("BOTTOMRIGHT", win.foot, "BOTTOMRIGHT", 2, -3)
        hover:EnableMouse(true)
        hover:SetScript("OnEnter", function(self)
            local earned, spent, ein, eout = {}, {}, 0, 0
            for _, r in ipairs(Filtered()) do
                if r[5] > 0 then earned[r[3]] = (earned[r[3]] or 0) + r[5]; ein = ein + r[5]
                else spent[r[3]] = (spent[r[3]] or 0) - r[5]; eout = eout - r[5] end
            end
            local function Section(title, t, total, r, g, b)
                GameTooltip:AddDoubleLine(title, Coin(total), r, g, b, 1, 1, 1)
                local list = {}
                for src, v in pairs(t) do list[#list + 1] = { src, v } end
                table.sort(list, function(a, b2) return a[2] > b2[2] end)
                for _, e in ipairs(list) do
                    GameTooltip:AddDoubleLine("   " .. e[1], Coin(e[2]), 1, 1, 1, 1, 1, 1)
                end
                if #list == 0 then GameTooltip:AddLine("   nothing", 0.5, 0.5, 0.5) end
            end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddDoubleLine(who and ColoredName(DB.chars[who]) or "All characters", RANGES[range][1],
                1, 1, 1, 0.7, 0.7, 0.7)
            Section("Earned", earned, ein, 0.4, 1, 0.4)
            GameTooltip:AddLine(" ")
            Section("Spent", spent, eout, 1, 0.45, 0.45)
            GameTooltip:Show()
        end)
        hover:SetScript("OnLeave", function() GameTooltip:Hide() end)
        local tip = win:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        tip:SetPoint("BOTTOMLEFT", 20, 30)
        win.tip = tip
        tip:SetText("")
        win:SetScript("OnShow", LedgerRefresh)
        win:Hide()          -- new frames start shown; the first click then opens it
    end

    OpenLedger = function()
        if not win then Build() end
        -- opens on this character, today
        if win:IsShown() then win:Hide() else who = me; range = 1; source = nil; offset = 0; win:Show() end
    end

    -----------------------------------------------------------------------
    -- Minimap button (drag it around the minimap's edge)
    -----------------------------------------------------------------------
    local function MinimapButton()
        if not Minimap or _G.ForeverItemTrackerMinimapButton then return end
        local b = CreateFrame("Button", "ForeverItemTrackerMinimapButton", Minimap)
        b:SetSize(31, 31)
        b:SetFrameStrata("MEDIUM")
        b:SetFrameLevel(8)
        b:RegisterForClicks("LeftButtonUp")
        b:RegisterForDrag("LeftButton")
        local icon = b:CreateTexture(nil, "BACKGROUND")
        icon:SetSize(20, 20)
        icon:SetPoint("CENTER", 0, 1)
        icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        local border = b:CreateTexture(nil, "OVERLAY")
        border:SetSize(53, 53)
        border:SetPoint("TOPLEFT")
        border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
        b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
        local function Place()
            local a = math.rad(DB.minimapAngle or 200)
            local r = (Minimap:GetWidth() / 2) + 5
            b:ClearAllPoints()
            b:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
        end
        Place()
        b:SetScript("OnDragStart", function(self)
            self:SetScript("OnUpdate", function()
                local mx, my = Minimap:GetCenter()
                local s = Minimap:GetEffectiveScale()
                local cx, cy = GetCursorPosition()
                DB.minimapAngle = math.deg(math.atan2(cy / s - my, cx / s - mx))
                Place()
            end)
        end)
        b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
        b:SetScript("OnClick", function() OpenLedger() end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine("Ledger")
            GameTooltip:AddLine("Click to open. Drag to move this button.", 0.6, 0.6, 0.6, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    ev:HookScript("OnEvent", function(_, e)
        if e == "PLAYER_ENTERING_WORLD" and DB then
            MinimapButton()
            for _, c in pairs(DB.chars) do c.ledger = nil end   -- the old daily totals
            -- fold rows recorded one by one before Loot / Other were added up
            -- earlier versions filed sales made right after a repair as Repair
            if DB.ledger and not DB.ledgerRepairFix then
                for _, r in ipairs(DB.ledger) do
                    if r[3] == "Repair" and r[5] > 0 then           -- repairs happen at vendors
                        r[3], r[4] = "Vendor", "sold item"
                    end
                end
                DB.ledgerRepairFix = true
            end
            if DB.ledger and not DB.ledgerRolled2 then
                local old = DB.ledger
                DB.ledger = {}
                for _, r in ipairs(old) do
                    if r[3] == "Other" then r[3] = "Loot" end     -- that was group loot
                    if ROLLUP[r[3]] then
                        if not AddToRollup(r[3], r[2], r[1], r[5], r[7] or 1) then
                            local n = r[7] or 1
                            table.insert(DB.ledger, { r[1], r[2], r[3], RollupText(r[3], n), r[5], r[6], n })
                        end
                    else
                        table.insert(DB.ledger, r)
                    end
                end
                DB.ledgerRolled, DB.ledgerRolled2 = nil, true
            end
        end
    end)
end

SLASH_FITP1 = "/fitp"
SLASH_FITP2 = "/itemtracker"
SlashCmdList.FITP = function(msg)
    local cmd, arg = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    if cmd == "ledger" then
        OpenLedger()
    elseif cmd == "scanlog" then
        Msg("scan log (%d lines):", #scanLog)
        for _, line in ipairs(scanLog) do Msg("  %s", line) end
        local p = DB.prices[priceKey]
        Msg("  last good scan: %s", p and p.time and (Ago(time() - p.time)) or "never")
        if C_AuctionHouse and C_AuctionHouse.IsThrottledMessageSystemReady then
            Msg("  auction house ready for searches right now: %s",
                tostring(C_AuctionHouse.IsThrottledMessageSystemReady()))
        end
    elseif cmd == "scan" then
        if ahOpen then TryScan(true) else Msg("open the auction house first.") end
    elseif cmd == "auto" then
        DB.auto = not DB.auto
        Msg("automatic scanning %s.", DB.auto and "on" or "off")
    elseif cmd == "gold" then
        local total = 0
        for _, k in ipairs(SortedChars()) do
            local c = DB.chars[k]
            Msg("%s  %s", ColoredName(c), Coin(c.gold or 0))
            total = total + (c.gold or 0)
        end
        Msg("Total  %s", Coin(total))
    elseif cmd == "deposit" then
        MoveItems(BAGS, BANK, "deposit")
    elseif cmd == "withdraw" then
        MoveItems(BANK, BAGS, "withdraw")
    elseif cmd == "bags" then
        local function show(label, list)
            local parts = {}
            for _, id in ipairs(list) do
                local ok, n = pcall(NumSlots, id)
                parts[#parts + 1] = id .. "(" .. ((ok and n) or 0) .. ")"
            end
            Msg("%s: %s", label, table.concat(parts, " "))
        end
        show("bags", BAGS)
        show("bank", BANK)
        local extra = {}
        local known = {}
        for _, id in ipairs(BAGS) do known[id] = true end
        for _, id in ipairs(BANK) do known[id] = true end
        for id = -5, 20 do
            local ok, n = pcall(NumSlots, id)
            if not known[id] and ok and (n or 0) > 0 then extra[#extra + 1] = id .. "(" .. n .. ")" end
        end
        Msg("not scanned but has slots: %s", #extra > 0 and table.concat(extra, " ") or "none")
    elseif cmd == "forget" and arg ~= "" then
        local want = (arg:find("-") and arg or (arg .. "-" .. realm)):lower()
        for k in pairs(DB.chars) do
            if k:lower() == want then
                if k == me then Msg("you can't forget the character you're logged in on.") return end
                DB.chars[k] = nil
                Msg("forgot %s.", k)
                return
            end
        end
        Msg("no character named %s.", arg)
    else
        Msg("/fitp ledger  |  /fitp scan  |  /fitp auto  |  /fitp gold  |  /fitp deposit  |  /fitp withdraw  |  /fitp bags  |  /fitp forget Name[-Realm]")
    end
end
