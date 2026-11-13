-- Forever Item Tracker PLUS: what each of your characters holds, and the last auction house price,
-- added to item and gold tooltips. Nothing else.

local ADDON = ...
local PREFIX = "|cff33ff99Forever Item Tracker PLUS|r: "
local STALE = 12 * 3600        -- scan age shown in red after this many seconds
local MIN_RESCAN = 15 * 60     -- the server allows one full scan per 15 minutes

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
local function ShowProgress(text, frac, hideAfter)
    local b = ProgressUI()
    if not b then return end
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

local function Process()
    StopWaiting()
    local getN, getInfo = Accessors()
    local n = getN() or 0
    if n == 0 then
        scanning = false
        Msg("the scan came back empty; it will retry later.")
        ShowProgress("Scan came back empty; will retry", nil, 5)
        return
    end
    local items, i = {}, 1
    local function step()
        -- stop if the AH closed or a normal search replaced the results
        if not ahOpen or (getN() or 0) ~= n then
            scanning = false
            Msg("scan interrupted; it will retry later.")
            ShowProgress("Scan interrupted; will retry", nil, 5)
            return
        end
        ShowProgress(string.format("Scanning: reading auctions  %d%%", math.floor((i - 1) / n * 100)), (i - 1) / n)
        local last = math.min(i + 2499, n)
        for j = i, last do
            local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, id = getInfo(j)
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
            p.items, p.time = items, time()
            scanning = false
            local k = 0
            for _ in pairs(items) do k = k + 1 end
            Msg("scanned %d auctions (%d items).", n, k)
            ShowProgress(string.format("Scan complete: %s auctions in %ds", Comma(n), Elapsed()), 1, 5)
        end
    end
    step()
end

local function TryScan(manual)
    if not ahOpen then return end
    if scanning then
        if manual then Msg("already scanning.") end
        return
    end
    if not manual then
        local p = Prices()
        if not DB.auto or (p.time and time() - p.time < MIN_RESCAN) then return end
    end
    if QueryAuctionItems then
        local _, canAll = CanSendAuctionQuery()
        if not canAll then
            if manual then Msg("the server allows one full scan every 15 minutes; try again shortly.") end
            return
        end
        scanning, awaiting = true, true
        QueryAuctionItems("", nil, nil, 0, false, nil, true, false, nil)
    elseif C_AuctionHouse and C_AuctionHouse.ReplicateItems then
        scanning, awaiting = true, true
        C_AuctionHouse.ReplicateItems()
    else
        return
    end
    Msg("scanning the auction house...")
    scanStart = GetTime()
    ShowProgress("Scanning: waiting for server  0s")
    StopWaiting()
    waitTicker = C_Timer.NewTicker(0.25, function()
        ShowProgress(string.format("Scanning: waiting for server  %ds", Elapsed()))
    end)
    C_Timer.After(90, function()
        if awaiting then
            awaiting, scanning = false, false
            StopWaiting()
            ShowProgress("Scan timed out; will retry", nil, 5)
        end
    end)
end

local function OnScanData()
    if not awaiting then return end
    awaiting = false
    C_Timer.After(1, Process)
end

---------------------------------------------------------------------------
-- Tooltips
---------------------------------------------------------------------------
local function AddItemLines(tt, id)
    local started, total, rows = false, 0, 0
    for _, k in ipairs(SortedChars()) do
        local c = DB.chars[k]
        local parts, sum = {}, 0
        for _, loc in ipairs(LOCS) do
            local n = c[loc] and c[loc][id]
            if n and n > 0 then
                parts[#parts + 1] = ICON[loc] .. " " .. n
                sum = sum + n
            end
        end
        if sum > 0 then
            if not started then tt:AddLine(" "); started = true end
            tt:AddDoubleLine(ColoredName(c), table.concat(parts, "   "), 1, 1, 1, 1, 1, 1)
            total, rows = total + sum, rows + 1
        end
    end
    if rows > 1 then tt:AddDoubleLine("Total", total, .6, .6, .6, .6, .6, .6) end

    local bind = ItemInfo and select(14, ItemInfo(id))
    if bind == 1 or bind == 4 then return end -- bind on pickup / quest items can't be sold
    if not started then tt:AddLine(" ") end
    local p = DB.prices[priceKey]
    if p and p.time then
        local age = time() - p.time
        local label = "AH " .. (age > STALE and "|cffff3333" or "|cff808080") .. Ago(age) .. "|r"
        local v = p.items[id]
        tt:AddDoubleLine(label, v and Coin(v) or "|cff808080none listed|r", 1, .82, 0, 1, 1, 1)
    else
        tt:AddDoubleLine("AH", "|cff808080no scan yet|r", 1, .82, 0, 1, 1, 1)
    end
end

local function OnItemTooltip(tt)
    if not DB or tt.fitpDone then return end
    if tt ~= GameTooltip and tt ~= ItemRefTooltip then return end
    local _, link = tt:GetItem()
    local id = LinkID(link)
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
    end
    for _, tt in ipairs({ GameTooltip, ItemRefTooltip }) do
        tt:HookScript("OnTooltipCleared", function(self) self.fitpDone = nil end)
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

local function CostLine(parent, anchor)
    local t = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t:SetJustifyH("LEFT")
    t:SetWidth(290)
    if anchor then
        t:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 4, -6)
    else
        t:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 24, 84)
    end
    return t
end

-- api: numReagents(i), reagentInfo(i, r) -> name, tex, need, have, reagentLink(i, r), itemLink(i), numMade(i)
local function ShowCost(line, index, api)
    if not index or index == 0 then line:SetText("") return end
    local p = DB.prices[priceKey]
    if not (p and p.time) then
        line:SetText("|cffffd100Crafting cost|r  |cff808080scan the auction house first|r")
        return
    end
    local total, missing = 0, {}
    local n = api.numReagents(index) or 0
    for r = 1, n do
        local name, _, need = api.reagentInfo(index, r)
        local id = LinkID(api.reagentLink(index, r))
        local each = id and p.items[id]
        if each then
            total = total + each * (need or 1)
        else
            missing[#missing + 1] = name or "?"
        end
    end
    local text = "|cffffd100Crafting cost|r  " .. Coin(total)
    if #missing > 0 then
        text = text .. "  |cff808080(+ " .. table.concat(missing, ", ") .. ": not on the AH)|r"
    end
    -- what it sells for, after the AH's cut
    local made = api.itemLink and LinkID(api.itemLink(index))
    local value = made and p.items[made]
    if value then
        local lo, hi = 1, 1
        if api.numMade then lo, hi = api.numMade(index) end
        local count = ((lo or 1) + (hi or lo or 1)) / 2
        local net = math.floor(value * count * (1 - AH_CUT))
        local profit = net - total
        text = text .. "\n|cffffd100Sells for|r  " .. Coin(net) .. " after AH cut   "
            .. (profit >= 0 and ("|cff33ff33+" .. Coin(profit) .. "|r") or ("|cffff3333-" .. Coin(-profit) .. "|r"))
            .. (#missing > 0 and " |cff808080(before the missing reagents)|r" or "")
    end
    local age = time() - p.time
    text = text .. "\n|cff808080prices from the AH scan " .. (age > STALE and "|cffff3333" or "") .. Ago(age) .. "|r"
    line:SetText(text)
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
        tradeLine = CostLine(_G.TradeSkillDetailScrollChildFrame or TradeSkillFrame,
            _G.TradeSkillReagent7 or _G.TradeSkillDetailScrollFrame)
        if TradeSkillFrame_SetSelection then hooksecurefunc("TradeSkillFrame_SetSelection", RefreshTrade) end
        TradeSkillFrame:HookScript("OnShow", RefreshTrade)
    end
    if CraftFrame and not craftLine and GetCraftReagentInfo then
        craftLine = CostLine(_G.CraftDetailScrollChildFrame or CraftFrame,
            _G.CraftReagent7 or _G.CraftDetailScrollFrame)
        if CraftFrame_SetSelection then hooksecurefunc("CraftFrame_SetSelection", RefreshCraft) end
        CraftFrame:HookScript("OnShow", RefreshCraft)
    end
end

H.TRADE_SKILL_UPDATE = function() RefreshTrade() end
H.CRAFT_UPDATE = function() RefreshCraft() end

function H.ADDON_LOADED(name)
    if name == "Blizzard_TradeSkillUI" or name == "Blizzard_CraftUI" then
        if DB then HookProfessions() end
        return
    end
    if name ~= ADDON then return end
    ForeverItemTrackerPlusDB = ForeverItemTrackerPlusDB or {}
    DB = ForeverItemTrackerPlusDB
    DB.chars = DB.chars or {}
    DB.prices = DB.prices or {}
    if DB.auto == nil then DB.auto = true end
end

function H.PLAYER_LOGIN()
    realm = GetRealmName()
    local name = UnitName("player")
    me = name .. "-" .. realm
    priceKey = realm .. "-" .. (UnitFactionGroup("player") or "?")
    local c = Me()
    c.name, c.realm, c.class = name, realm, select(2, UnitClass("player"))
    c.gold = GetMoney()
    ScanBags()
    ScanEquip()

    HookTooltips()
    if HandleModifiedItemClick then hooksecurefunc("HandleModifiedItemClick", OnModifiedItemClick) end
    HookAllMoney()
    HookProfessions()                 -- (if the professions windows are already loaded)

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

function H.AUCTION_HOUSE_SHOW()
    ahOpen = true
    C_Timer.After(1, function() TryScan() end)
    if ticker then ticker:Cancel() end
    ticker = C_Timer.NewTicker(30, function() TryScan() end)
end
function H.AUCTION_HOUSE_CLOSED()
    ahOpen, awaiting, scanning = false, false, false
    if ticker then ticker:Cancel(); ticker = nil end
    StopWaiting()
    if bar then bar:Hide() end
end
H.AUCTION_ITEM_LIST_UPDATE = OnScanData
H.REPLICATE_ITEM_LIST_UPDATE = OnScanData

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
SLASH_FITP1 = "/fitp"
SLASH_FITP2 = "/itemtracker"
SlashCmdList.FITP = function(msg)
    local cmd, arg = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    if cmd == "scan" then
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
        Msg("/fitp scan  |  /fitp auto  |  /fitp gold  |  /fitp deposit  |  /fitp withdraw  |  /fitp bags  |  /fitp forget Name[-Realm]")
    end
end
