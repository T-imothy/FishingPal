local addonName = ...

local FishingPal = CreateFrame("Frame")
local VERSION = "1.0.2-11402"
local FISHING_SPELL_ID = 7620
local DOUBLE_CLICK_WINDOW = 0.36
local MINIMAP_BUTTON_RADIUS = 80
local DEFAULT_MINIMAP_ANGLE = math.rad(225)
local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

local defaults = {
    version = VERSION,
    options = {
        easyCast = true,
        watcher = true,
        lureAlerts = true,
        soundMode = false,
    },
    positions = {},
    stats = {
        casts = 0,
        catches = 0,
        items = {},
        zones = {},
    },
    gear = {
        fishing = {},
        normal = {},
    },
}

local db
local initialized = false
local panel, watcher, minimapButton
local panelStatus, panelStats
local easyCastButton, watcherButton, lureButton, soundButton
local watcherZone, watcherSummary, watcherLure
local watcherItems = {}
local pendingGearSet
local minimapDragging = false
local minimapWasDragged = false
local lastRightClick = 0
local lastFishingCast = 0
local lastRecordedCast = 0
local lastLootHandled = 0
local lastLureWarning = 0
local updateElapsed = 0

local session = {
    startedAt = GetTime(),
    casts = 0,
    catches = 0,
    items = {},
}

local soundCVars = {
    "Sound_EnableAllSound",
    "Sound_EnableSFX",
    "Sound_EnableMusic",
    "Sound_EnableAmbience",
    "Sound_SFXVolume",
    "Sound_EnableSoundWhenGameIsInBG",
}

local function FillDefaults(target, source)
    for key, value in pairs(source) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then target[key] = {} end
            FillDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

local function EmptyTable(target)
    if wipe then
        wipe(target)
    else
        for key in pairs(target) do target[key] = nil end
    end
end

local function Chat(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33d6ffFishingPal|r |cffffffff(Developed by Tim):|r " .. message)
    end
end

local function FormatDuration(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local remaining = seconds % 60
    if hours > 0 then return string.format("%dh %02dm", hours, minutes) end
    return string.format("%dm %02ds", minutes, remaining)
end

local function GetZoneKey()
    local zone = (GetRealZoneText and GetRealZoneText()) or (GetZoneText and GetZoneText()) or "Unknown Zone"
    local subzone = (GetSubZoneText and GetSubZoneText()) or ""
    if subzone ~= "" and subzone ~= zone then
        return zone .. " - " .. subzone
    end
    return zone ~= "" and zone or "Unknown Zone"
end

local function GetFishingSpellName()
    return (GetSpellInfo and GetSpellInfo(FISHING_SPELL_ID)) or "Fishing"
end

local function IsFishingSpell(spellID)
    if spellID == FISHING_SPELL_ID then return true end
    if spellID and GetSpellInfo then
        local name = GetSpellInfo(spellID)
        return name and name == GetFishingSpellName()
    end
    return false
end

local function IsFishingPoleEquipped()
    local link = GetInventoryItemLink and GetInventoryItemLink("player", 16)
    if not link then return false end

    if GetItemInfoInstant then
        local _, _, _, _, _, classID, subclassID = GetItemInfoInstant(link)
        if classID == 2 and subclassID == 20 then return true end
    end

    if GetItemInfo then
        local _, _, _, _, _, itemType, itemSubType, _, equipLocation, _, _, classID, subclassID = GetItemInfo(link)
        if classID == 2 and subclassID == 20 then return true end
        if equipLocation == "INVTYPE_2HWEAPON" and itemSubType then
            local lowered = string.lower(itemSubType)
            if string.find(lowered, "fishing", 1, true) then return true end
        end
        if itemType and itemSubType and string.find(string.lower(itemSubType), "fishing", 1, true) then
            return true
        end
    end
    return false
end

local function GetLureStatus()
    if not IsFishingPoleEquipped() then return false, 0, "Equip a fishing pole" end
    local hasEnchant, expiration = GetWeaponEnchantInfo()
    if hasEnchant then
        local seconds = math.max(0, math.floor((expiration or 0) / 1000))
        return true, seconds, "Lure active: " .. FormatDuration(seconds)
    end
    return false, 0, "No lure active"
end

local function SafeGetCVar(name)
    if not GetCVar then return nil end
    local ok, value = pcall(GetCVar, name)
    if ok then return value end
    return nil
end

local function SafeSetCVar(name, value)
    if SetCVar and value ~= nil then pcall(SetCVar, name, value) end
end

local function ApplySoundValues()
    SafeSetCVar("Sound_EnableAllSound", "1")
    SafeSetCVar("Sound_EnableSFX", "1")
    SafeSetCVar("Sound_EnableMusic", "0")
    SafeSetCVar("Sound_EnableAmbience", "0")
    SafeSetCVar("Sound_SFXVolume", "1")
    SafeSetCVar("Sound_EnableSoundWhenGameIsInBG", "1")
end

local function RestoreSoundValues(clearBackup)
    if db and type(db.soundBackup) == "table" then
        for name, value in pairs(db.soundBackup) do SafeSetCVar(name, value) end
        if clearBackup then db.soundBackup = nil end
    end
end

local function SetSoundMode(enabled)
    if enabled then
        if type(db.soundBackup) ~= "table" then
            db.soundBackup = {}
            for _, name in ipairs(soundCVars) do
                local value = SafeGetCVar(name)
                if value ~= nil then db.soundBackup[name] = value end
            end
        end
        db.options.soundMode = true
        ApplySoundValues()
        Chat("Fishing sound mode enabled.")
    else
        RestoreSoundValues(true)
        db.options.soundMode = false
        Chat("Previous sound settings restored.")
    end
end

local function CaptureGearSet()
    local set = {}
    for slot = 1, 19 do
        set[slot] = GetInventoryItemLink("player", slot) or false
    end
    return set
end

local function SaveFishingGear()
    db.gear.fishing = CaptureGearSet()
    Chat("Current equipment saved as the FishingPal fishing set.")
end

local function GearSetHasItems(set)
    if type(set) ~= "table" then return false end
    for _, value in pairs(set) do
        if type(value) == "string" and value ~= "" then return true end
    end
    return false
end

local function EquipGearSet(kind)
    if InCombatLockdown and InCombatLockdown() then
        pendingGearSet = kind
        Chat("Gear change queued until combat ends.")
        return
    end

    local set = db.gear[kind]
    if not GearSetHasItems(set) then
        Chat(kind == "fishing" and "Save a fishing set first." or "No previous gear set is available.")
        return
    end

    for slot = 1, 19 do
        local item = set[slot]
        if type(item) == "string" and item ~= "" then
            pcall(EquipItemByName, item, slot)
        end
    end
    Chat(kind == "fishing" and "Fishing gear equipped." or "Previous gear restored.")
end

local function EquipFishingGear()
    if not GearSetHasItems(db.gear.fishing) then
        Chat("Save a fishing set first.")
        return
    end
    db.gear.normal = CaptureGearSet()
    EquipGearSet("fishing")
end

local function ResetSession()
    session.startedAt = GetTime()
    session.casts = 0
    session.catches = 0
    EmptyTable(session.items)
    Chat("Session statistics reset.")
end

local function ResetAllStats()
    db.stats = { casts = 0, catches = 0, items = {}, zones = {} }
    ResetSession()
    Chat("All FishingPal statistics reset.")
end

local function IncrementItem(tableRef, key, name, quantity, quality)
    local entry = tableRef[key]
    if type(entry) ~= "table" then
        entry = { name = name, count = 0, quality = quality or 1 }
        tableRef[key] = entry
    end
    entry.name = name or entry.name
    entry.quality = quality or entry.quality or 1
    entry.count = (entry.count or 0) + quantity
end

local function RecordCatch(link, name, quantity, quality)
    quantity = math.max(1, tonumber(quantity) or 1)
    local itemID = link and string.match(link, "item:(%d+)")
    local key = itemID or link or name or "unknown"
    name = name or (link and string.match(link, "%[(.-)%]")) or "Unknown Catch"

    session.catches = session.catches + quantity
    db.stats.catches = (db.stats.catches or 0) + quantity
    IncrementItem(session.items, key, name, quantity, quality)
    IncrementItem(db.stats.items, key, name, quantity, quality)

    local zoneKey = GetZoneKey()
    local zone = db.stats.zones[zoneKey]
    if type(zone) ~= "table" then
        zone = { catches = 0, items = {} }
        db.stats.zones[zoneKey] = zone
    end
    zone.catches = (zone.catches or 0) + quantity
    IncrementItem(zone.items, key, name, quantity, quality)
end

local function RecordFishingLoot()
    if not lastFishingCast or lastFishingCast <= 0 or GetTime() - lastFishingCast > 45 then return end
    if GetTime() - lastLootHandled < 0.3 then return end
    lastLootHandled = GetTime()

    local foundItem = false
    local slots = GetNumLootItems and GetNumLootItems() or 0
    for slot = 1, slots do
        local link = GetLootSlotLink and GetLootSlotLink(slot)
        if link then
            local _, lootName, quantity, fourthValue, fifthValue = GetLootSlotInfo(slot)
            local quality
            if type(fifthValue) == "number" then
                quality = fifthValue
            elseif type(fourthValue) == "number" then
                quality = fourthValue
            end
            RecordCatch(link, lootName, quantity, quality)
            foundItem = true
        end
    end
    if foundItem then lastFishingCast = 0 end
end

local function WarnIfNoLure()
    if not db.options.lureAlerts or not IsFishingPoleEquipped() then return end
    local hasLure = GetLureStatus()
    if not hasLure and GetTime() - lastLureWarning > 60 then
        lastLureWarning = GetTime()
        Chat("No lure is active on your fishing pole.")
        if PlaySound then
            if SOUNDKIT and SOUNDKIT.TELL_MESSAGE then
                pcall(PlaySound, SOUNDKIT.TELL_MESSAGE, "Master")
            else
                pcall(PlaySound, 3081, "Master")
            end
        end
    end
end

local function HandleFishingCast(spellID)
    if not IsFishingSpell(spellID) then return end
    local now = GetTime()
    lastFishingCast = now
    if now - lastRecordedCast > 1 then
        lastRecordedCast = now
        session.casts = session.casts + 1
        db.stats.casts = (db.stats.casts or 0) + 1
        WarnIfNoLure()
    end
end

local function SortedItems(source)
    local result = {}
    for key, value in pairs(source or {}) do
        if type(value) == "table" then
            result[#result + 1] = {
                key = key,
                name = value.name or "Unknown Catch",
                count = value.count or 0,
                quality = value.quality or 1,
            }
        end
    end
    table.sort(result, function(a, b)
        if a.count == b.count then return a.name < b.name end
        return a.count > b.count
    end)
    return result
end

local function QualityColor(quality)
    if GetItemQualityColor then
        local r, g, b = GetItemQualityColor(quality or 1)
        if r then
            return string.format(
                "|cff%02x%02x%02x",
                math.floor((r * 255) + 0.5),
                math.floor((g * 255) + 0.5),
                math.floor((b * 255) + 0.5)
            )
        end
    end
    return "|cffffffff"
end

local function CreateFlatButton(parent, text, width, height)
    local button = CreateFrame("Button", nil, parent, BACKDROP_TEMPLATE)
    button:SetSize(width, height or 28)
    if button.SetBackdrop then
        button:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        button:SetBackdropColor(0.055, 0.085, 0.12, 0.98)
        button:SetBackdropBorderColor(0.08, 0.62, 0.85, 0.95)
    end
    button.label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.label:SetPoint("CENTER")
    button.label:SetText(text or "")
    function button:SetLabel(value) self.label:SetText(value or "") end
    button:SetScript("OnEnter", function(self)
        if self.SetBackdropColor then self:SetBackdropColor(0.07, 0.28, 0.39, 1) end
        if self.SetBackdropBorderColor then self:SetBackdropBorderColor(0.25, 0.85, 1, 1) end
    end)
    button:SetScript("OnLeave", function(self)
        if self.SetBackdropColor then self:SetBackdropColor(0.055, 0.085, 0.12, 0.98) end
        if self.SetBackdropBorderColor then self:SetBackdropBorderColor(0.08, 0.62, 0.85, 0.95) end
    end)
    button:SetScript("OnMouseDown", function(self)
        self.label:SetPoint("CENTER", 1, -1)
    end)
    button:SetScript("OnMouseUp", function(self)
        self.label:SetPoint("CENTER")
    end)
    return button
end

local function ApplyPanelBackdrop(frame, alpha)
    if not frame.SetBackdrop then return end
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 2,
    })
    frame:SetBackdropColor(0.018, 0.032, 0.052, alpha or 0.96)
    frame:SetBackdropBorderColor(0.08, 0.68, 0.92, 1)
end

local function SaveFramePosition(frame, key)
    local centerX, centerY = frame:GetCenter()
    if centerX and centerY then
        db.positions[key] = {
            x = centerX - (UIParent:GetWidth() / 2),
            y = centerY - (UIParent:GetHeight() / 2),
        }
    end
end

local function RestoreFramePosition(frame, key, defaultX, defaultY)
    local saved = db.positions[key]
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", saved and saved.x or defaultX or 0, saved and saved.y or defaultY or 0)
end

local function SetMinimapButtonAngle(angle, save)
    if not minimapButton then return end
    angle = tonumber(angle) or DEFAULT_MINIMAP_ANGLE
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint(
        "CENTER",
        Minimap,
        "CENTER",
        math.cos(angle) * MINIMAP_BUTTON_RADIUS,
        math.sin(angle) * MINIMAP_BUTTON_RADIUS
    )
    if save then db.positions.minimapAngle = angle end
end

local function UpdateMinimapButtonFromCursor()
    if not GetCursorPosition or not Minimap or not Minimap.GetCenter then return end
    local cursorX, cursorY = GetCursorPosition()
    local centerX, centerY = Minimap:GetCenter()
    if not cursorX or not cursorY or not centerX or not centerY then return end

    local scale = (UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 1
    cursorX, cursorY = cursorX / scale, cursorY / scale
    local deltaX, deltaY = cursorX - centerX, cursorY - centerY
    if deltaX == 0 and deltaY == 0 then return end

    local angle
    if deltaX == 0 then
        angle = deltaY > 0 and (math.pi / 2) or (-math.pi / 2)
    else
        angle = math.atan(deltaY / deltaX)
        if deltaX < 0 then angle = angle + math.pi end
    end
    SetMinimapButtonAngle(angle, true)
end

local function UpdateInterface()
    if not initialized then return end
    local zoneKey = GetZoneKey()
    local zoneStats = db.stats.zones[zoneKey] or { catches = 0, items = {} }
    local hasLure, _, lureText = GetLureStatus()
    local poleText = IsFishingPoleEquipped() and "Fishing pole equipped" or "Fishing pole not equipped"

    if easyCastButton then easyCastButton:SetLabel("Easy Cast: " .. (db.options.easyCast and "ON" or "OFF")) end
    if watcherButton then watcherButton:SetLabel("Watcher: " .. (db.options.watcher and "ON" or "OFF")) end
    if lureButton then lureButton:SetLabel("Lure Alerts: " .. (db.options.lureAlerts and "ON" or "OFF")) end
    if soundButton then soundButton:SetLabel("Sound Focus: " .. (db.options.soundMode and "ON" or "OFF")) end

    if panelStatus then
        panelStatus:SetText(string.format(
            "%s\n%s | Session: %d casts, %d catches | Zone lifetime: %d catches",
            poleText,
            lureText,
            session.casts,
            session.catches,
            zoneStats.catches or 0
        ))
        panelStatus:SetTextColor(hasLure and 0.55 or 0.95, hasLure and 0.95 or 0.72, hasLure and 1 or 0.25)
    end

    if panelStats then
        local lifetime = SortedItems(db.stats.items)
        local lines = {
            string.format("Current zone: %s", zoneKey),
            string.format("Session time: %s", FormatDuration(GetTime() - session.startedAt)),
            string.format("Lifetime: %d casts, %d catches", db.stats.casts or 0, db.stats.catches or 0),
            "",
            "Most-caught items:",
        }
        if #lifetime == 0 then
            lines[#lines + 1] = "No catches recorded yet."
        else
            for index = 1, math.min(8, #lifetime) do
                local item = lifetime[index]
                lines[#lines + 1] = string.format("%s%s|r  x%d", QualityColor(item.quality), item.name, item.count)
            end
        end
        panelStats:SetText(table.concat(lines, "\n"))
    end

    if watcher then
        watcher:SetShown(db.options.watcher)
        watcherZone:SetText(zoneKey)
        watcherSummary:SetText(string.format(
            "Session  %d casts  •  %d catches  •  %s",
            session.casts,
            session.catches,
            FormatDuration(GetTime() - session.startedAt)
        ))
        watcherLure:SetText(lureText)
        watcherLure:SetTextColor(hasLure and 0.35 or 1, hasLure and 0.92 or 0.65, hasLure and 1 or 0.2)
        local items = SortedItems(session.items)
        for index, line in ipairs(watcherItems) do
            local item = items[index]
            if item then
                line:SetText(string.format("%s%s|r  x%d", QualityColor(item.quality), item.name, item.count))
            else
                line:SetText(index == 1 and "No catches this session yet." or "")
            end
        end
    end
end

local function TogglePanel()
    if not panel then return end
    if panel:IsShown() then panel:Hide() else panel:Show(); UpdateInterface() end
end

local function CreateWatcher()
    watcher = CreateFrame("Frame", "FishingPalWatcher", UIParent, BACKDROP_TEMPLATE)
    watcher:SetSize(340, 252)
    watcher:SetFrameStrata("MEDIUM")
    watcher:SetClampedToScreen(true)
    watcher:SetMovable(true)
    watcher:EnableMouse(true)
    watcher:RegisterForDrag("LeftButton")
    watcher:SetScript("OnDragStart", watcher.StartMoving)
    watcher:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveFramePosition(self, "watcher")
    end)
    ApplyPanelBackdrop(watcher, 0.92)
    RestoreFramePosition(watcher, "watcher", 370, 40)

    local title = watcher:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText("FishingPal")
    title:SetTextColor(0.25, 0.85, 1)

    local author = watcher:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    author:SetPoint("LEFT", title, "RIGHT", 10, -1)
    author:SetText("Developed by Tim")
    author:SetTextColor(0.62, 0.72, 0.82)

    local line = watcher:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(0.08, 0.68, 0.92, 0.55)
    line:SetPoint("TOPLEFT", 14, -42)
    line:SetPoint("TOPRIGHT", -14, -42)
    line:SetHeight(1)

    watcherZone = watcher:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    watcherZone:SetPoint("TOPLEFT", 16, -54)
    watcherZone:SetPoint("RIGHT", -16, 0)
    watcherZone:SetJustifyH("LEFT")

    watcherSummary = watcher:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    watcherSummary:SetPoint("TOPLEFT", watcherZone, "BOTTOMLEFT", 0, -7)
    watcherSummary:SetTextColor(0.70, 0.80, 0.88)

    watcherLure = watcher:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    watcherLure:SetPoint("TOPLEFT", watcherSummary, "BOTTOMLEFT", 0, -6)

    for index = 1, 5 do
        local itemLine = watcher:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        itemLine:SetPoint("TOPLEFT", 20, -112 - ((index - 1) * 19))
        itemLine:SetPoint("RIGHT", -16, 0)
        itemLine:SetJustifyH("LEFT")
        watcherItems[index] = itemLine
    end

    local resetSessionButton = CreateFlatButton(watcher, "Reset Session", 124, 26)
    resetSessionButton:SetPoint("BOTTOMRIGHT", -14, 12)
    resetSessionButton:SetScript("OnClick", function()
        ResetSession()
        UpdateInterface()
    end)

    watcher:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then TogglePanel() end
    end)
end

local function CreatePanel()
    panel = CreateFrame("Frame", "FishingPalControlPanel", UIParent, BACKDROP_TEMPLATE)
    panel:SetSize(610, 620)
    panel:SetFrameStrata("DIALOG")
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveFramePosition(self, "panel")
    end)
    ApplyPanelBackdrop(panel, 0.97)
    RestoreFramePosition(panel, "panel", 0, 0)
    panel:Hide()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -18)
    title:SetText("FishingPal")
    title:SetTextColor(0.25, 0.85, 1)

    local author = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    author:SetPoint("TOP", title, "BOTTOM", 0, -4)
    author:SetText("Developed by Tim")
    author:SetTextColor(0.68, 0.78, 0.88)

    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.08, 0.68, 0.92, 0.6)
    divider:SetPoint("TOPLEFT", 22, -66)
    divider:SetPoint("TOPRIGHT", -22, -66)
    divider:SetHeight(1)

    local close = CreateFlatButton(panel, "X", 28, 28)
    close:SetPoint("TOPRIGHT", -10, -10)
    close:SetScript("OnClick", function() panel:Hide() end)

    local statusTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusTitle:SetPoint("TOPLEFT", 24, -82)
    statusTitle:SetText("CURRENT STATUS")
    statusTitle:SetTextColor(0.25, 0.85, 1)

    panelStatus = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panelStatus:SetPoint("TOPLEFT", statusTitle, "BOTTOMLEFT", 0, -10)
    panelStatus:SetPoint("RIGHT", -24, 0)
    panelStatus:SetHeight(54)
    panelStatus:SetJustifyH("LEFT")
    panelStatus:SetJustifyV("TOP")

    local toolsTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    toolsTitle:SetPoint("TOPLEFT", 24, -178)
    toolsTitle:SetText("FISHING TOOLS")
    toolsTitle:SetTextColor(0.25, 0.85, 1)

    easyCastButton = CreateFlatButton(panel, "Easy Cast", 132)
    easyCastButton:SetPoint("TOPLEFT", 24, -202)
    easyCastButton:SetScript("OnClick", function()
        db.options.easyCast = not db.options.easyCast
        UpdateInterface()
    end)

    watcherButton = CreateFlatButton(panel, "Watcher", 132)
    watcherButton:SetPoint("LEFT", easyCastButton, "RIGHT", 10, 0)
    watcherButton:SetScript("OnClick", function()
        db.options.watcher = not db.options.watcher
        UpdateInterface()
    end)

    lureButton = CreateFlatButton(panel, "Lure Alerts", 132)
    lureButton:SetPoint("LEFT", watcherButton, "RIGHT", 10, 0)
    lureButton:SetScript("OnClick", function()
        db.options.lureAlerts = not db.options.lureAlerts
        UpdateInterface()
    end)

    soundButton = CreateFlatButton(panel, "Sound Focus", 132)
    soundButton:SetPoint("LEFT", lureButton, "RIGHT", 10, 0)
    soundButton:SetScript("OnClick", function()
        SetSoundMode(not db.options.soundMode)
        UpdateInterface()
    end)

    local easyHelp = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    easyHelp:SetPoint("TOPLEFT", 26, -241)
    easyHelp:SetPoint("RIGHT", -24, 0)
    easyHelp:SetJustifyH("LEFT")
    easyHelp:SetText("Easy Cast: double-right-click the game world while a fishing pole is equipped.")
    easyHelp:SetTextColor(0.62, 0.72, 0.82)

    local gearTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    gearTitle:SetPoint("TOPLEFT", 24, -282)
    gearTitle:SetText("FISHING GEAR")
    gearTitle:SetTextColor(0.25, 0.85, 1)

    local saveGear = CreateFlatButton(panel, "Save Current as Fishing Set", 180)
    saveGear:SetPoint("TOPLEFT", 24, -306)
    saveGear:SetScript("OnClick", function()
        SaveFishingGear()
        UpdateInterface()
    end)

    local equipGear = CreateFlatButton(panel, "Equip Fishing Set", 170)
    equipGear:SetPoint("LEFT", saveGear, "RIGHT", 10, 0)
    equipGear:SetScript("OnClick", EquipFishingGear)

    local restoreGear = CreateFlatButton(panel, "Restore Previous Gear", 170)
    restoreGear:SetPoint("LEFT", equipGear, "RIGHT", 10, 0)
    restoreGear:SetScript("OnClick", function() EquipGearSet("normal") end)

    local statsTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statsTitle:SetPoint("TOPLEFT", 24, -366)
    statsTitle:SetText("CATCH STATISTICS")
    statsTitle:SetTextColor(0.25, 0.85, 1)

    panelStats = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panelStats:SetPoint("TOPLEFT", 26, -392)
    panelStats:SetPoint("BOTTOMRIGHT", -26, 78)
    panelStats:SetJustifyH("LEFT")
    panelStats:SetJustifyV("TOP")

    local resetSessionButton = CreateFlatButton(panel, "Reset Session", 150)
    resetSessionButton:SetPoint("BOTTOMLEFT", 24, 26)
    resetSessionButton:SetScript("OnClick", function()
        ResetSession()
        UpdateInterface()
    end)

    local resetAllButton = CreateFlatButton(panel, "Shift-click: Reset All Stats", 190)
    resetAllButton:SetPoint("LEFT", resetSessionButton, "RIGHT", 10, 0)
    resetAllButton:SetScript("OnClick", function()
        if IsShiftKeyDown() then
            ResetAllStats()
            UpdateInterface()
        else
            Chat("Hold Shift while clicking Reset All Stats.")
        end
    end)

    local version = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    version:SetPoint("BOTTOMRIGHT", -24, 33)
    version:SetText(VERSION)

    panel:SetScript("OnShow", UpdateInterface)
end

local function CreateMinimapButton()
    minimapButton = CreateFrame("Button", "FishingPalMinimapButton", Minimap, BACKDROP_TEMPLATE)
    minimapButton:SetSize(31, 31)
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:RegisterForDrag("LeftButton")
    SetMinimapButtonAngle(db.positions.minimapAngle, false)

    local background = minimapButton:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetSize(22, 22)
    background:SetPoint("CENTER")

    local icon = minimapButton:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\Trade_Fishing")
    icon:SetSize(19, 19)
    icon:SetPoint("CENTER")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    if minimapButton.CreateMaskTexture and icon.AddMaskTexture then
        local mask = minimapButton:CreateMaskTexture()
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
        mask:SetAllPoints(icon)
        icon:AddMaskTexture(mask)
    end

    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    minimapButton:SetScript("OnClick", function(_, button)
        if minimapWasDragged then
            minimapWasDragged = false
            return
        end
        if button == "RightButton" then
            db.options.watcher = not db.options.watcher
            UpdateInterface()
        else
            TogglePanel()
        end
    end)
    minimapButton:SetScript("OnEnter", function(self)
        icon:SetVertexColor(0.65, 0.95, 1)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("FishingPal", 0.25, 0.85, 1)
        GameTooltip:AddLine("Developed by Tim", 0.75, 0.82, 0.90)
        GameTooltip:AddLine("Left-click: settings", 1, 1, 1)
        GameTooltip:AddLine("Left-drag: move around minimap", 1, 1, 1)
        GameTooltip:AddLine("Right-click: toggle watcher", 1, 1, 1)
        GameTooltip:Show()
    end)
    minimapButton:SetScript("OnLeave", function()
        icon:SetVertexColor(1, 1, 1)
        GameTooltip:Hide()
    end)
    minimapButton:SetScript("OnDragStart", function()
        minimapDragging = true
        minimapWasDragged = true
        UpdateMinimapButtonFromCursor()
    end)
    minimapButton:SetScript("OnDragStop", function()
        UpdateMinimapButtonFromCursor()
        minimapDragging = false
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function() minimapWasDragged = false end)
        end
    end)
    minimapButton:SetScript("OnUpdate", function()
        if minimapDragging then UpdateMinimapButtonFromCursor() end
    end)
end

local function InstallEasyCast()
    if not WorldFrame or not WorldFrame.HookScript then return end
    WorldFrame:HookScript("OnMouseDown", function(_, button)
        if not initialized or button ~= "RightButton" or not db.options.easyCast then return end
        local now = GetTime()
        if now - lastRightClick <= DOUBLE_CLICK_WINDOW then
            lastRightClick = 0
            if InCombatLockdown and InCombatLockdown() then return end
            if SpellIsTargeting and SpellIsTargeting() then return end
            if CursorHasItem and CursorHasItem() then return end
            if not IsFishingPoleEquipped() then
                Chat("Equip a fishing pole before using Easy Cast.")
                return
            end
            local spellName = GetFishingSpellName()
            if spellName and CastSpellByName then pcall(CastSpellByName, spellName) end
        else
            lastRightClick = now
        end
    end)
end

local function Initialize()
    FishingPalDB = type(FishingPalDB) == "table" and FishingPalDB or {}
    FillDefaults(FishingPalDB, defaults)
    FishingPalDB.version = VERSION
    db = FishingPalDB
    session.startedAt = GetTime()

    CreateWatcher()
    CreatePanel()
    CreateMinimapButton()
    InstallEasyCast()

    if db.options.soundMode then ApplySoundValues() end
    initialized = true
    UpdateInterface()
    Chat("Loaded. Use /fpal or click the minimap fishing icon.")
end

SLASH_FISHINGPAL1 = "/fishingpal"
SLASH_FISHINGPAL2 = "/fpal"
SlashCmdList.FISHINGPAL = function(message)
    if not initialized then return end
    local command, argument = string.match(message or "", "^%s*(%S*)%s*(.-)%s*$")
    command = string.lower(command or "")
    argument = string.lower(argument or "")

    if command == "watch" or command == "watcher" then
        db.options.watcher = not db.options.watcher
        UpdateInterface()
    elseif command == "sound" then
        SetSoundMode(not db.options.soundMode)
        UpdateInterface()
    elseif command == "gear" and argument == "save" then
        SaveFishingGear()
    elseif command == "gear" and argument == "equip" then
        EquipFishingGear()
    elseif command == "gear" and argument == "restore" then
        EquipGearSet("normal")
    elseif command == "reset" then
        ResetSession()
        UpdateInterface()
    elseif command == "help" then
        Chat("/fpal - open settings")
        Chat("/fpal watch - toggle the live watcher")
        Chat("/fpal sound - toggle fishing sound focus")
        Chat("/fpal gear save - save your current fishing set")
        Chat("/fpal gear equip - save current gear and equip the fishing set")
        Chat("/fpal gear restore - restore your previous gear")
        Chat("/fpal reset - reset this session")
    else
        TogglePanel()
    end
end

FishingPal:RegisterEvent("ADDON_LOADED")
FishingPal:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon ~= addonName then return end
        Initialize()
        FishingPal:RegisterEvent("PLAYER_LOGIN")
        FishingPal:RegisterEvent("ZONE_CHANGED")
        FishingPal:RegisterEvent("ZONE_CHANGED_INDOORS")
        FishingPal:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        FishingPal:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        FishingPal:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
        FishingPal:RegisterEvent("LOOT_OPENED")
        FishingPal:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
        FishingPal:RegisterEvent("BAG_UPDATE_DELAYED")
        FishingPal:RegisterEvent("PLAYER_REGEN_ENABLED")
        FishingPal:RegisterEvent("PLAYER_LOGOUT")
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        local unit, _, spellID = ...
        if unit == "player" then HandleFishingCast(spellID) end
    elseif event == "LOOT_OPENED" then
        RecordFishingLoot()
        UpdateInterface()
    elseif event == "PLAYER_REGEN_ENABLED" and pendingGearSet then
        local kind = pendingGearSet
        pendingGearSet = nil
        EquipGearSet(kind)
    elseif event == "PLAYER_LOGOUT" then
        if db and db.options.soundMode then RestoreSoundValues(false) end
    else
        UpdateInterface()
    end
end)

FishingPal:SetScript("OnUpdate", function(_, elapsed)
    if not initialized then return end
    updateElapsed = updateElapsed + elapsed
    if updateElapsed >= 1 then
        updateElapsed = 0
        if lastFishingCast > 0 and GetTime() - lastFishingCast > 45 then lastFishingCast = 0 end
        UpdateInterface()
    end
end)
