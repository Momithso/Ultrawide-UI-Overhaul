local MOD_NAME = "Ultrawide UI Overhaul"
local VERSION = "2.2.1"
local LOG_PREFIX = "[UltrawideUIOverhaul]"
local DEBUG = false

-- Temporary lifecycle diagnostics for the Backpack CTD hotfix test.
local BACKPACK_LAYOUT_ENABLED = true
local BACKPACK_LIFECYCLE_DIAGNOSTICS = false
local BACKPACK_LIFECYCLE_DIAGNOSTIC_FILE =
    "backpack_lifecycle_diagnostic.log"

-- Diagnostic build switch:
--   true  = write live main-menu diagnostics for testers
--   false = production build; no diagnostic file or diagnostic I/O
local MAIN_MENU_DIAGNOSTICS = false
local MAIN_MENU_DIAGNOSTIC_FILE = "main_menu_diagnostic.log"

-- Temporary development probe for feature/backpack-overhaul. Remove before
-- release: it writes one complete inventory_wrapper subtree per CET session.
local BACKPACK_TREE_DIAGNOSTICS = false
local BACKPACK_TREE_DIAGNOSTIC_FILE = "backpack_inventory_wrapper_dump.log"
local BACKPACK_CONTROLLER_DIAGNOSTICS = false
local BACKPACK_CONTROLLER_DIAGNOSTIC_FILE = "backpack_controller_dump.log"
local BACKPACK_RMK_DIAGNOSTICS = false
local BACKPACK_RMK_DIAGNOSTIC_FILE = "backpack_rmk_search_dump.log"
local CRAFTING_TREE_DIAGNOSTICS = false
local CRAFTING_TREE_DIAGNOSTIC_FILE = "crafting_panel_dump.log"
local CRAFTING_CONTROLLER_DIAGNOSTICS = false
local CRAFTING_CONTROLLER_DIAGNOSTIC_FILE = "crafting_controller_dump.log"
local GALLERY_CONTROLLER_DIAGNOSTICS = false
local GALLERY_CONTROLLER_DIAGNOSTIC_FILE = "gallery_controller_dump.log"
local SHARDS_TREE_DIAGNOSTICS = false
local SHARDS_TREE_DIAGNOSTIC_FILE = "shards_entry_view_dump.log"
local STASH_TREE_DIAGNOSTICS = false
local STASH_TREE_DIAGNOSTIC_FILE = "stash_widget_tree_dump.log"
local STASH_CONTROLLER_DIAGNOSTICS = false
local STASH_CONTROLLER_DIAGNOSTIC_FILE = "stash_grid_controller_dump.log"
local GALLERY_VANILLA_SCREENSHOTS_PER_PAGE = 10
local VANILLA_ASPECT = 16.0 / 9.0

local REFERENCE_HEIGHT = 2160.0
local VIEWPORT_HEIGHT = 1080.0
local CAMERA_HEIGHT = 720
local VANILLA_CONTENT_WIDTH = 3840.0
local LEGACY_21X9_CONTENT_WIDTH = 5160.0
-- Include exact 2:1 modes such as 2880x1440 and 3840x1920. A small tolerance
-- protects configured/live-resolution rounding without enabling ordinary
-- 16:9 layouts.
local MIN_SUPPORTED_ASPECT = 1.99
local MAX_SUPPORTED_ASPECT = 3.65
local MAX_21X9_ASPECT = 2.45
local MIN_32X9_ASPECT = 3.45

local pendingLayouts = {}
local backpackLayoutAppliedControllers = {}
local activeHubMenu = ""
-- Never assume that CET initialization happens on the pre-game menu. A
-- Reload All Mods performed in the playable world recreates this script too;
-- arming the long main-menu search there makes the first subsequently opened
-- Ink menu get recursively scanned for roughly one minute.
local mainMenuRetryBudget = 0
local mainMenuRetryTimer = 0.0
local mainMenuPillarTimer = 0.0
local mainMenuPillarPending = false
local mainMenuPillarsDisabled = false
local mainMenuDiagnosticAttempt = 0
local mainMenuDiagnosticSignature = ""
local mainMenuSceneReadyPasses = 0
local stealthRunnerRetryBudget = 0
local stealthRunnerRetryTimer = 0.0
local stealthRunnerScanTimer = 0.0
local backpackTreeDumped = false
local backpackTreeScanTimer = 0.0
local backpackTreeDumpFailed = false
local backpackControllerDumped = false
local backpackControllerDumpFailed = false
local backpackRmkDumped = false
local craftingTreeDumped = false
local craftingTreeDumpFailed = false
local craftingControllerDumped = false
local craftingControllerDumpFailed = false
local craftingGridRebuiltControllers = {}
local galleryControllerDumped = false
local galleryControllerDumpFailed = false
local shardsTreeDumped = false
local shardsTreeDumpFailed = false
local deathMenuActive = false
local stashMenuActive = false
local stashLayoutFinalized = false
local stashGeometryApplied = false
local stashDataViewsRefreshed = false
local stashPlayerInventoryPopulated = false
local stashVendorInventoryPopulated = false
local stashDataRefreshScheduled = false
local stashTreeDumped = false
local stashControllerDumped = false
local menuHintWidgetNames = {
    cyberware_equip = "button_hints",
    backpack = "button_hints",
    crafting_main = "buttonHintContainer",
    temp_stats = "button_hints",
    gallery = "inputHints",
    shards = "button_hints"
}

local function debugLog(message)
    if DEBUG then print(message) end
end

local function initializeDiagnosticLog()
    if not MAIN_MENU_DIAGNOSTICS then return end

    local file = io.open(MAIN_MENU_DIAGNOSTIC_FILE, "w")
    if file ~= nil then
        file:write(string.format(
            "[%s] [MainMenuDiagnostics] diagnostic logging initialized\n",
            os.date("%Y-%m-%d %H:%M:%S")
        ))
        file:flush()
        file:close()
    end
end

local function diagnosticLog(message)
    if not MAIN_MENU_DIAGNOSTICS then return end

    local file = io.open(MAIN_MENU_DIAGNOSTIC_FILE, "a")
    if file ~= nil then
        file:write(string.format(
            "[%s] [MainMenuDiagnostics] %s\n",
            os.date("%Y-%m-%d %H:%M:%S"), tostring(message)
        ))
        file:flush()
        file:close()
    end
end

local function safe(callback)
    local ok, value = pcall(callback)
    return ok and value or nil
end

local function backpackLifecycleLog(message)
    if not BACKPACK_LIFECYCLE_DIAGNOSTICS then return end
    local file = io.open(BACKPACK_LIFECYCLE_DIAGNOSTIC_FILE, "a")
    if file ~= nil then
        file:write(string.format(
            "[%s] [BackpackLifecycle] %s\n",
            os.date("%Y-%m-%d %H:%M:%S"), tostring(message)
        ))
        file:flush()
        file:close()
    end
end

local function isPreGame()
    return safe(function()
        local handler = Game.GetSystemRequestsHandler()
        if handler == nil then return nil end
        return handler:IsPreGame()
    end)
end

local function cancelMainMenuRetries(reason)
    if mainMenuRetryBudget <= 0 then return end
    diagnosticLog(string.format(
        "in-game menu detected (%s); cancelling %d main-menu retries",
        tostring(reason), mainMenuRetryBudget
    ))
    mainMenuRetryBudget = 0
    mainMenuRetryTimer = 0.0
    mainMenuSceneReadyPasses = 0
end

local function ensureMenuPillarsDisabled(reason)
    -- A delayed/finalization pass may execute after the player has already
    -- selected a save and entered a loading transition. Only a live menu
    -- event is allowed to repair the compositor state.
    local normalizedReason = string.lower(tostring(reason or ""))
    if string.find(normalizedReason, "delayed", 1, true) ~= nil or
       string.find(normalizedReason, "finalize", 1, true) ~= nil then
        return
    end

    local ok, errorMessage = pcall(function()
        local coordinator = GetMod("BlackPillarsCoordinator")
        if coordinator ~= nil and coordinator.SetPillarsDisabled ~= nil then
            coordinator.SetPillarsDisabled(true)
        elseif UWMenuSetPillarsDisabled ~= nil then
            UWMenuSetPillarsDisabled(true)
        else
            UWMapSetBlackBarsSuppressed(true)
        end
    end)
    if not ok then
        debugLog(string.format(
            "%s failed to disable menu pillars (%s): %s",
            LOG_PREFIX, tostring(reason), tostring(errorMessage)
        ))
    end
end

local function widgetName(widget)
    return safe(function() return widget:GetName().value end) or ""
end

local function cnameEquals(value, expected)
    local rawValue = safe(function() return value.value end)
    return rawValue == expected or tostring(value) == expected
end

local function cnameValue(value)
    return safe(function() return value.value end) or tostring(value)
end

local function collectByName(root, wantedName, maxDepth)
    local matches = {}

    local function visit(widget, depth)
        if widget == nil then return end

        if widgetName(widget) == wantedName then
            table.insert(matches, widget)
        end

        if depth >= maxDepth then return end

        local count = safe(function() return widget:GetNumChildren() end)
        if count == nil then return end

        for index = 0, count - 1 do
            visit(safe(function() return widget:GetWidget(index) end), depth + 1)
        end
    end

    visit(root, 0)
    return matches
end

local function resizeNamedWidgets(root, name, width, height)
    local resized = 0
    for _, widget in ipairs(collectByName(root, name, 12)) do
        local ok = pcall(function()
            widget:SetSize(width, height)
            widget:SetMargin(0.0, 0.0, 0.0, 0.0)
        end)
        if ok then resized = resized + 1 end
    end
    return resized
end

local function getTargetGeometry()
    local displayWidth, displayHeight = GetDisplayResolution()
    if displayWidth == nil or displayHeight == nil or displayHeight <= 0 then
        return nil
    end

    local aspect = displayWidth / displayHeight
    if aspect < MIN_SUPPORTED_ASPECT or aspect > MAX_SUPPORTED_ASPECT then
        return nil
    end

    local profile = "intermediate ultrawide"
    if aspect < 2.30 then
        profile = "2:1"
    elseif aspect <= MAX_21X9_ASPECT then
        profile = "21:9"
    elseif aspect >= MIN_32X9_ASPECT then
        profile = "32:9"
    end

    return {
        aspect = aspect,
        profile = profile,
        viewportWidth = aspect * VIEWPORT_HEIGHT,
        contentWidth = aspect * REFERENCE_HEIGHT,
        cameraWidth = math.floor(aspect * CAMERA_HEIGHT + 0.5),
        cameraHeight = CAMERA_HEIGHT
    }
end

local function getGalleryScreenshotsPerPage()
    local geometry = getTargetGeometry()
    if geometry == nil then
        return GALLERY_VANILLA_SCREENSHOTS_PER_PAGE
    end

    -- Gallery uses two rows. Between 2:1 and 21:9, increase its five vanilla
    -- columns only when another complete column actually fits: five columns
    -- at 2:1, then six, then the validated seven columns at 21:9.
    if geometry.contentWidth < LEGACY_21X9_CONTENT_WIDTH then
        local twoToOneWidth = 2.0 * REFERENCE_HEIGHT
        local progress = math.max(0.0, math.min(
            1.0,
            (geometry.contentWidth - twoToOneWidth) /
            (LEGACY_21X9_CONTENT_WIDTH - twoToOneWidth)
        ))
        local columns = 5 + math.floor(progress * 2.0 + 0.5)
        return columns * 2
    end

    -- Scale the vanilla ten entries with the available aspect ratio. The
    -- upper rounding keeps a newly exposed partial slot usable: 14 entries
    -- at 21:9 and 20 entries at 32:9.
    return math.max(
        GALLERY_VANILLA_SCREENSHOTS_PER_PAGE,
        math.ceil(
            GALLERY_VANILLA_SCREENSHOTS_PER_PAGE *
            geometry.aspect / VANILLA_ASPECT - 0.000001
        )
    )
end

-- FrameSwitcherMenuGameController (the SmartFrame picture picker) derives
-- from GalleryMenuGameController. CET therefore delivers the parent-class
-- OnInitialize observers for both screens. Only the full Gallery may use the
-- ultrawide page size: the SmartFrame picker has a fixed nine-slot layout and
-- must retain the page size authored for that controller.
local function isMainGalleryController(controller)
    if controller == nil then return false end

    local className = safe(function()
        return controller:GetClassName().value
    end)
    return className == "GalleryMenuGameController"
end

-- The original layouts were visually tuned at 16:9 and 21:9. Keep the exact
-- 21:9 values, extend them beyond 21:9, and interpolate them back toward the
-- vanilla canvas for narrower ultrawide modes such as 2:1.
local function getExtraHorizontalInset(geometry)
    return (geometry.contentWidth - LEGACY_21X9_CONTENT_WIDTH) * 0.5
end

local function extendMarginToEdge(margin, geometry)
    return margin - getExtraHorizontalInset(geometry)
end

local function preserveCenteredMargin(margin, geometry)
    return margin + getExtraHorizontalInset(geometry)
end

local function interpolateToLegacy21x9(vanillaValue, legacy21x9Value, geometry)
    local progress = math.max(0.0, math.min(
        1.0,
        (geometry.contentWidth - VANILLA_CONTENT_WIDTH) /
        (LEGACY_21X9_CONTENT_WIDTH - VANILLA_CONTENT_WIDTH)
    ))
    return vanillaValue + (legacy21x9Value - vanillaValue) * progress
end

local function extendLegacy21x9Value(vanillaValue, legacy21x9Value, geometry)
    return interpolateToLegacy21x9(vanillaValue, legacy21x9Value, geometry) +
        math.max(0.0, geometry.contentWidth - LEGACY_21X9_CONTENT_WIDTH)
end

local function dumpBackpackWidgetTree(root)
    if not BACKPACK_TREE_DIAGNOSTICS or root == nil or
        backpackTreeDumped or backpackTreeDumpFailed then
        return false
    end

    local file = io.open(BACKPACK_TREE_DIAGNOSTIC_FILE, "w")
    if file == nil then
        print(LOG_PREFIX .. " failed to open backpack tree diagnostic file")
        backpackTreeDumpFailed = true
        return false
    end

    local function vectorText(value)
        return value ~= nil and string.format("%.2f,%.2f", value.X, value.Y) or "nil"
    end

    local function marginText(value)
        return value ~= nil and string.format(
            "%.2f,%.2f,%.2f,%.2f",
            value.left, value.top, value.right, value.bottom
        ) or "nil"
    end

    local function rectText(value)
        return value ~= nil and string.format(
            "L%.2f,T%.2f,R%.2f,B%.2f,W%.2f,H%.2f",
            value.Left, value.Top, value.Right, value.Bottom,
            value.Right - value.Left, value.Bottom - value.Top
        ) or "nil"
    end

    local function valueText(callback)
        local value = safe(callback)
        return value ~= nil and tostring(value) or "nil"
    end

    local function visit(widget, depth, path)
        if widget == nil or depth > 16 then return end

        local childCount = safe(function() return widget:GetNumChildren() end) or 0
        local className = valueText(function() return widget:GetClassName() end)
        file:write(string.format(
            "%s%s | class=%s children=%d size=%s desired=%s screen=%s margin=%s padding=%s anchor=%s anchorPoint=%s hAlign=%s vAlign=%s sizeRule=%s fit=%s scale=%s translation=%s visible=%s opacity=%s interactive=%s affectsLayoutWhenHidden=%s\n",
            string.rep("  ", depth), path, className, childCount,
            vectorText(safe(function() return widget:GetSize() end)),
            vectorText(safe(function() return widget:GetDesiredSize() end)),
            rectText(safe(function() return GetScreenPosition(widget) end)),
            marginText(safe(function() return widget:GetMargin() end)),
            marginText(safe(function() return widget:GetPadding() end)),
            valueText(function() return widget:GetAnchor() end),
            vectorText(safe(function() return widget:GetAnchorPoint() end)),
            valueText(function() return widget:GetHAlign() end),
            valueText(function() return widget:GetVAlign() end),
            valueText(function() return widget:GetSizeRule() end),
            valueText(function() return widget:GetFitToContent() end),
            vectorText(safe(function() return widget:GetScale() end)),
            vectorText(safe(function() return widget:GetTranslation() end)),
            valueText(function() return widget:IsVisible() end),
            valueText(function() return widget:GetOpacity() end),
            valueText(function() return widget:IsInteractive() end),
            valueText(function() return widget:GetAffectsLayoutWhenHidden() end)
        ))

        for index = 0, childCount - 1 do
            local child = safe(function() return widget:GetWidget(index) end)
            if child ~= nil then
                local name = widgetName(child)
                if name == "" then name = "<unnamed>" end
                visit(child, depth + 1, string.format("%s/%s[%d]", path, name, index))
            end
        end
    end

    file:write(string.format(
        "Ultrawide UI Overhaul backpack tree dump | %s\n",
        os.date("%Y-%m-%d %H:%M:%S")
    ))
    visit(root, 0, "inventory_wrapper")
    file:flush()
    file:close()
    backpackTreeDumped = true
    print(LOG_PREFIX .. " backpack inventory_wrapper tree dumped")
    return true
end

local function dumpShardsEntryViewTree(root)
    if not SHARDS_TREE_DIAGNOSTICS or root == nil or
       shardsTreeDumped or shardsTreeDumpFailed then
        return false
    end

    local file = io.open(SHARDS_TREE_DIAGNOSTIC_FILE, "w")
    if file == nil then
        print(LOG_PREFIX .. " failed to open shards tree diagnostic file")
        shardsTreeDumpFailed = true
        return false
    end

    local function vectorText(value)
        return value ~= nil and string.format("%.2f,%.2f", value.X, value.Y) or "nil"
    end

    local function marginText(value)
        return value ~= nil and string.format(
            "%.2f,%.2f,%.2f,%.2f",
            value.left, value.top, value.right, value.bottom
        ) or "nil"
    end

    local function rectText(value)
        return value ~= nil and string.format(
            "L%.2f,T%.2f,R%.2f,B%.2f,W%.2f,H%.2f",
            value.Left, value.Top, value.Right, value.Bottom,
            value.Right - value.Left, value.Bottom - value.Top
        ) or "nil"
    end

    local function valueText(callback)
        local value = safe(callback)
        return value ~= nil and tostring(value) or "nil"
    end

    local function visit(widget, depth, path)
        if widget == nil or depth > 16 then return end

        local childCount = safe(function() return widget:GetNumChildren() end) or 0
        file:write(string.format(
            "%s%s | class=%s children=%d size=%s desired=%s screen=%s margin=%s padding=%s anchor=%s anchorPoint=%s hAlign=%s vAlign=%s sizeRule=%s fit=%s scale=%s translation=%s visible=%s\n",
            string.rep("  ", depth), path,
            valueText(function() return widget:GetClassName() end), childCount,
            vectorText(safe(function() return widget:GetSize() end)),
            vectorText(safe(function() return widget:GetDesiredSize() end)),
            rectText(safe(function() return GetScreenPosition(widget) end)),
            marginText(safe(function() return widget:GetMargin() end)),
            marginText(safe(function() return widget:GetPadding() end)),
            valueText(function() return widget:GetAnchor() end),
            vectorText(safe(function() return widget:GetAnchorPoint() end)),
            valueText(function() return widget:GetHAlign() end),
            valueText(function() return widget:GetVAlign() end),
            valueText(function() return widget:GetSizeRule() end),
            valueText(function() return widget:GetFitToContent() end),
            vectorText(safe(function() return widget:GetScale() end)),
            vectorText(safe(function() return widget:GetTranslation() end)),
            valueText(function() return widget:IsVisible() end)
        ))

        for index = 0, childCount - 1 do
            local child = safe(function() return widget:GetWidget(index) end)
            if child ~= nil then
                local name = widgetName(child)
                if name == "" then name = "<unnamed>" end
                visit(child, depth + 1, string.format(
                    "%s/%s[%d]", path, name, index
                ))
            end
        end
    end

    file:write(string.format(
        "Ultrawide UI Overhaul shards entryView tree dump | %s\n",
        os.date("%Y-%m-%d %H:%M:%S")
    ))
    visit(root, 0, "entryView")
    file:flush()
    file:close()
    shardsTreeDumped = true
    print(LOG_PREFIX .. " shards entryView tree dumped")
    return true
end

local function dumpBackpackControllers(controller, inventoryWrapper)
    if not BACKPACK_CONTROLLER_DIAGNOSTICS or backpackControllerDumped or
        backpackControllerDumpFailed or inventoryWrapper == nil then
        return false
    end

    local file = io.open(BACKPACK_CONTROLLER_DIAGNOSTIC_FILE, "w")
    if file == nil then
        print(LOG_PREFIX .. " failed to open backpack controller diagnostic file")
        backpackControllerDumpFailed = true
        return false
    end

    local function className(value)
        return safe(function() return value:GetClassName().value end) or
            safe(function() return value:GetClassName() end) or "nil"
    end

    local function dumpObject(label, value)
        file:write(string.format("\n===== %s | class=%s =====\n", label, className(value)))
        if value == nil then
            file:write("nil\n")
            return
        end

        local dump = safe(function() return GameDump(value) end)
        file:write(dump ~= nil and tostring(dump) or "GameDump unavailable or failed")
        file:write("\n")
    end

    file:write(string.format(
        "Ultrawide UI Overhaul backpack controller dump | %s\n",
        os.date("%Y-%m-%d %H:%M:%S")
    ))

    dumpObject("applyBackpackLayout controller", controller)
    dumpObject("inventory_wrapper.logicController",
        safe(function() return inventoryWrapper.logicController end))
    dumpObject("inventory_wrapper:GetController()",
        safe(function() return inventoryWrapper:GetController() end))

    for _, virtualGrid in ipairs(
        collectByName(inventoryWrapper, "inkVirtualCompoundWidget4", 12)
    ) do
        dumpObject("inkVirtualCompoundWidget4 widget", virtualGrid)
        dumpObject("inkVirtualCompoundWidget4.logicController",
            safe(function() return virtualGrid.logicController end))
        dumpObject("inkVirtualCompoundWidget4:GetController()",
            safe(function() return virtualGrid:GetController() end))
    end

    file:flush()
    file:close()
    backpackControllerDumped = true
    print(LOG_PREFIX .. " backpack controllers dumped")
    return true
end

local function dumpBackpackRmkSearch(searchContainer)
    if not BACKPACK_RMK_DIAGNOSTICS or backpackRmkDumped or
        searchContainer == nil then return end

    local file = io.open(BACKPACK_RMK_DIAGNOSTIC_FILE, "w")
    if file == nil then return end

    local function vectorText(value)
        return value ~= nil and string.format("%.2f,%.2f", value.X, value.Y) or "nil"
    end
    local function marginText(value)
        return value ~= nil and string.format(
            "%.2f,%.2f,%.2f,%.2f",
            value.left, value.top, value.right, value.bottom
        ) or "nil"
    end
    local function rectText(value)
        return value ~= nil and string.format(
            "L%.2f,T%.2f,R%.2f,B%.2f,W%.2f,H%.2f",
            value.Left, value.Top, value.Right, value.Bottom,
            value.Right - value.Left, value.Bottom - value.Top
        ) or "nil"
    end

    file:write(string.format(
        "Ultrawide UI Overhaul RMK search dump | %s\n",
        os.date("%Y-%m-%d %H:%M:%S")
    ))
    local widget = searchContainer
    for level = 0, 6 do
        if widget == nil then break end
        file:write(string.format(
            "ancestor%d name=%s class=%s size=%s desired=%s screen=%s margin=%s anchor=%s anchorPoint=%s h=%s v=%s scale=%s translation=%s\n",
            level,
            widgetName(widget),
            tostring(safe(function() return widget:GetClassName() end)),
            vectorText(safe(function() return widget:GetSize() end)),
            vectorText(safe(function() return widget:GetDesiredSize() end)),
            rectText(safe(function() return GetScreenPosition(widget) end)),
            marginText(safe(function() return widget:GetMargin() end)),
            tostring(safe(function() return widget:GetAnchor() end)),
            vectorText(safe(function() return widget:GetAnchorPoint() end)),
            tostring(safe(function() return widget:GetHAlign() end)),
            tostring(safe(function() return widget:GetVAlign() end)),
            vectorText(safe(function() return widget:GetScale() end)),
            vectorText(safe(function() return widget:GetTranslation() end))
        ))
        widget = safe(function() return widget:GetParentWidget() end)
    end

    file:flush()
    file:close()
    backpackRmkDumped = true
end

local function dumpCraftingWidgetTree(root)
    if not CRAFTING_TREE_DIAGNOSTICS or craftingTreeDumped or
        craftingTreeDumpFailed or root == nil then return false end

    local file = io.open(CRAFTING_TREE_DIAGNOSTIC_FILE, "w")
    if file == nil then
        craftingTreeDumpFailed = true
        return false
    end

    local function vectorText(value)
        return value ~= nil and string.format("%.2f,%.2f", value.X, value.Y) or "nil"
    end
    local function marginText(value)
        return value ~= nil and string.format(
            "%.2f,%.2f,%.2f,%.2f",
            value.left, value.top, value.right, value.bottom
        ) or "nil"
    end
    local function rectText(value)
        return value ~= nil and string.format(
            "L%.2f,T%.2f,R%.2f,B%.2f,W%.2f,H%.2f",
            value.Left, value.Top, value.Right, value.Bottom,
            value.Right - value.Left, value.Bottom - value.Top
        ) or "nil"
    end

    local function visit(widget, depth, path)
        if widget == nil or depth > 16 then return end
        local childCount = safe(function() return widget:GetNumChildren() end) or 0
        file:write(string.format(
            "%s%s | class=%s children=%d size=%s desired=%s screen=%s margin=%s padding=%s anchor=%s anchorPoint=%s h=%s v=%s rule=%s fit=%s scale=%s translation=%s visible=%s\n",
            string.rep("  ", depth), path,
            tostring(safe(function() return widget:GetClassName() end)),
            childCount,
            vectorText(safe(function() return widget:GetSize() end)),
            vectorText(safe(function() return widget:GetDesiredSize() end)),
            rectText(safe(function() return GetScreenPosition(widget) end)),
            marginText(safe(function() return widget:GetMargin() end)),
            marginText(safe(function() return widget:GetPadding() end)),
            tostring(safe(function() return widget:GetAnchor() end)),
            vectorText(safe(function() return widget:GetAnchorPoint() end)),
            tostring(safe(function() return widget:GetHAlign() end)),
            tostring(safe(function() return widget:GetVAlign() end)),
            tostring(safe(function() return widget:GetSizeRule() end)),
            tostring(safe(function() return widget:GetFitToContent() end)),
            vectorText(safe(function() return widget:GetScale() end)),
            vectorText(safe(function() return widget:GetTranslation() end)),
            tostring(safe(function() return widget:IsVisible() end))
        ))

        for index = 0, childCount - 1 do
            local child = safe(function() return widget:GetWidget(index) end)
            if child ~= nil then
                local name = widgetName(child)
                if name == "" then name = "<unnamed>" end
                visit(child, depth + 1,
                    string.format("%s/%s[%d]", path, name, index))
            end
        end
    end

    file:write(string.format(
        "Ultrawide UI Overhaul crafting tree dump | %s\n",
        os.date("%Y-%m-%d %H:%M:%S")
    ))
    visit(root, 0, "craftingPanel")
    file:flush()
    file:close()
    craftingTreeDumped = true
    return true
end

local function dumpCraftingControllers(controller, craftingPanel)
    if not CRAFTING_CONTROLLER_DIAGNOSTICS or craftingControllerDumped or
        craftingControllerDumpFailed or craftingPanel == nil then
        return false
    end

    local panelController = safe(function() return craftingPanel:GetController() end) or
        safe(function() return craftingPanel.logicController end)
    local virtualListController = panelController ~= nil and safe(function()
        return panelController.virtualListController
    end) or nil
    local dataView = panelController ~= nil and safe(function()
        return panelController.dataView
    end) or nil
    local dataSource = panelController ~= nil and safe(function()
        return panelController.dataSource
    end) or nil

    -- CraftingMainGameController.OnInitialize fires before its child crafting
    -- controller has connected the virtual grid and its data. Wait for a
    -- delayed layout pass; an early dump only reports NULL and hides the state
    -- that actually controls/rebuilds the recipe grid.
    if virtualListController == nil or dataView == nil or dataSource == nil then
        return false
    end

    local file = io.open(CRAFTING_CONTROLLER_DIAGNOSTIC_FILE, "w")
    if file == nil then
        craftingControllerDumpFailed = true
        print(LOG_PREFIX .. " failed to open crafting controller diagnostic file")
        return false
    end

    local function className(value)
        return safe(function() return value:GetClassName().value end) or
            safe(function() return value:GetClassName() end) or "nil"
    end

    local function dumpObject(label, value)
        file:write(string.format("\n===== %s | class=%s =====\n", label, className(value)))
        if value == nil then
            file:write("nil\n")
            return
        end

        local dump = safe(function() return GameDump(value) end)
        file:write(dump ~= nil and tostring(dump) or "GameDump unavailable or failed")
        file:write("\n")
    end

    file:write(string.format(
        "Ultrawide UI Overhaul crafting controller dump | %s\n",
        os.date("%Y-%m-%d %H:%M:%S")
    ))

    dumpObject("CraftingMainGameController", controller)
    dumpObject("craftingPanel.logicController",
        safe(function() return craftingPanel.logicController end))
    dumpObject("craftingPanel:GetController()", panelController)
    dumpObject("CraftingLogicController.virtualListController", virtualListController)
    dumpObject("CraftingLogicController.dataView", dataView)
    dumpObject("CraftingLogicController.dataSource", dataSource)

    for _, virtualList in ipairs(
        collectByName(craftingPanel, "virtualListContainer", 16)
    ) do
        dumpObject("virtualListContainer widget", virtualList)
        dumpObject("virtualListContainer.logicController",
            safe(function() return virtualList.logicController end))
        dumpObject("virtualListContainer:GetController()",
            safe(function() return virtualList:GetController() end))
    end

    file:flush()
    file:close()
    craftingControllerDumped = true
    print(LOG_PREFIX .. " crafting controllers dumped")
    return true
end

local function dumpGalleryControllers(controller, searchRoot)
    if not GALLERY_CONTROLLER_DIAGNOSTICS or galleryControllerDumped or
       galleryControllerDumpFailed or controller == nil or searchRoot == nil then
        return false
    end

    local screenshotAreas = collectByName(searchRoot, "screenshots_area", 24)
    if #screenshotAreas == 0 then return false end

    local file = io.open(GALLERY_CONTROLLER_DIAGNOSTIC_FILE, "w")
    if file == nil then
        galleryControllerDumpFailed = true
        print(LOG_PREFIX .. " failed to open gallery controller diagnostic file")
        return false
    end

    local function className(value)
        return safe(function() return value:GetClassName().value end) or
            safe(function() return value:GetClassName() end) or "nil"
    end

    local function dumpObject(label, value)
        file:write(string.format("\n===== %s | class=%s =====\n", label, className(value)))
        if value == nil then
            file:write("nil\n")
            return
        end
        local dump = safe(function() return GameDump(value) end)
        file:write(dump ~= nil and tostring(dump) or "GameDump unavailable or failed")
        file:write("\n")
    end

    file:write(string.format(
        "Ultrawide UI Overhaul gallery controller dump | %s\n",
        os.date("%Y-%m-%d %H:%M:%S")
    ))
    dumpObject("GalleryMenuGameController", controller)

    for areaIndex, screenshotArea in ipairs(screenshotAreas) do
        dumpObject("screenshots_area[" .. areaIndex .. "]", screenshotArea)
        dumpObject("screenshots_area.logicController",
            safe(function() return screenshotArea.logicController end))
        dumpObject("screenshots_area:GetController()",
            safe(function() return screenshotArea:GetController() end))

        for listIndex, list in ipairs(collectByName(screenshotArea, "list", 4)) do
            dumpObject("screenshots_area/list[" .. listIndex .. "]", list)
            dumpObject("list.logicController",
                safe(function() return list.logicController end))
            dumpObject("list:GetController()",
                safe(function() return list:GetController() end))
        end
    end

    file:flush()
    file:close()
    galleryControllerDumped = true
    print(LOG_PREFIX .. " gallery controllers dumped")
    return true
end

local function applyCraftingGridLayout(craftingPanel, geometry)
    if craftingPanel == nil or geometry == nil then return 0, false end

    -- The vanilla recipe viewport is 1350 wide. Consume the additional
    -- ultrawide canvas for the recipe side, plus one 220-wide cell that fits
    -- in the remaining gap without moving the details panel. This gives 2890
    -- at the legacy 21:9 reference width: twelve columns in total.
    local extraWidth = math.max(0.0, geometry.contentWidth - 3840.0)
    local gridWidth = 1350.0 + extraWidth + 220.0
    local listHolderWidth = gridWidth - 200.0
    local resized = 0

    for _, leftContainer in ipairs(collectByName(craftingPanel, "leftContainer", 4)) do
        local targets = {
            { name = "list_holder", width = listHolderWidth, height = 1400.0 },
            { name = "gridFrame", width = gridWidth + 2.0, height = 1520.0 },
            { name = "cache", width = gridWidth, height = 1400.0 },
            { name = "scroll_area", width = gridWidth, height = 1400.0 },
            { name = "virtualListContainer", width = gridWidth, height = 1400.0 }
        }

        for _, target in ipairs(targets) do
            for _, widget in ipairs(collectByName(leftContainer, target.name, 8)) do
                local ok = pcall(function()
                    widget:SetSize(target.width, target.height)
                    widget:FlagForVisualInvalidation()
                end)
                if ok then resized = resized + 1 end
            end
        end

    end

    -- Keep the details panel immediately to the right of the enlarged recipe
    -- viewport (1435 vanilla + the same ultrawide expansion).
    for _, detailsCanvas in ipairs(collectByName(craftingPanel, "inkCanvasWidget7", 3)) do
        pcall(function()
            local margin = detailsCanvas:GetMargin()
            detailsCanvas:SetMargin(
                1435.0 + extraWidth,
                margin ~= nil and margin.top or -40.0,
                margin ~= nil and margin.right or 0.0,
                margin ~= nil and margin.bottom or 0.0
            )
            detailsCanvas:FlagForVisualInvalidation()
        end)
    end

    local panelController = safe(function() return craftingPanel:GetController() end) or
        safe(function() return craftingPanel.logicController end)
    if panelController == nil or craftingGridRebuiltControllers[panelController] then
        return resized, false
    end

    local virtualListController = safe(function()
        return panelController.virtualListController
    end)
    local dataView = safe(function() return panelController.dataView end)
    if virtualListController == nil or dataView == nil then
        return resized, false
    end

    -- The virtual grid caches its column layout when SetSource is first called.
    -- Reassigning the existing view once makes it rebuild against gridWidth.
    local rebuilt = pcall(function()
        virtualListController:SetSource(nil)
        virtualListController:SetSource(dataView)
    end)
    if rebuilt then
        craftingGridRebuiltControllers[panelController] = true
    else
        print(LOG_PREFIX .. " crafting virtual grid rebuild failed")
    end

    return resized, rebuilt
end

local function positionRightFluff(root, geometry, maxDepth)
    if root == nil or geometry == nil then return 0 end

    local positioned = 0
    local horizontalInset = (geometry.contentWidth - 3840.0) * 0.5
    for _, widget in ipairs(collectByName(root, "Right_fluff_elements", maxDepth or 24)) do
        local ok = pcall(function()
            -- Keep the vanilla canvas intact and translate it to the 21:9
            -- right edge. Resizing it reverses the apparent displacement due
            -- to the anchoring of its internal artwork.
            widget:SetSize(3840.0, REFERENCE_HEIGHT)
            widget:SetMargin(horizontalInset - 3.0, -5.0, 0.0, 0.0)
        end)
        if ok then positioned = positioned + 1 end
    end
    return positioned
end

local function applyMenuShellLayout(geometry)
    local layer = safe(function()
        return Game.GetInkSystem():GetLayer(CName.new("inkMenuLayer"))
    end)
    local virtualWindow = layer ~= nil and safe(function()
        return layer:GetVirtualWindow()
    end) or nil
    if virtualWindow == nil then
        print(LOG_PREFIX .. " menu VirtualWindow unavailable")
        return
    end

    local resizedRoots = 0
    local function visitShell(widget, depth)
        if widget == nil or depth > 2 then return end

        local size = safe(function() return widget:GetSize() end)
        local name = widgetName(widget)
        if name == "Root" and size ~= nil and
            size.X >= 3800.0 and size.X <= 3860.0 and
            size.Y >= 2100.0 and size.Y <= 2200.0 then
            local ok = pcall(function()
                widget:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
                widget:SetMargin(0.0, 0.0, 0.0, 0.0)
            end)
            if ok then resizedRoots = resizedRoots + 1 end
        end

        local count = safe(function() return widget:GetNumChildren() end)
        if count == nil then return end
        for index = 0, count - 1 do
            visitShell(safe(function() return widget:GetWidget(index) end), depth + 1)
        end
    end

    visitShell(virtualWindow, 0)
    local topPanels = resizeNamedWidgets(
        virtualWindow, "topPanels", geometry.contentWidth, REFERENCE_HEIGHT
    )
    local backgroundFluff = resizeNamedWidgets(
        virtualWindow, "bgFluff", geometry.contentWidth, REFERENCE_HEIGHT
    )

    local rightLines = 0
    for _, widget in ipairs(collectByName(virtualWindow, "Right_lines", 12)) do
        local ok = pcall(function()
            widget:SetMargin(geometry.contentWidth - 55.0, 0.0, 0.0, 0.0)
        end)
        if ok then rightLines = rightLines + 1 end
    end

    local rightFluff = positionRightFluff(virtualWindow, geometry, 12)

    debugLog(string.format(
        "%s shell: roots=%d topPanels=%d bgFluff=%d rightLines=%d rightFluff=%d width=%.2f",
        LOG_PREFIX, resizedRoots, topPanels, backgroundFluff, rightLines, rightFluff,
        geometry.contentWidth
    ))
end

local function applyWorldMapLayout(controller, reason)
    cancelMainMenuRetries("world map " .. tostring(reason))
    ensureMenuPillarsDisabled("world map " .. tostring(reason))
    local geometry = getTargetGeometry()
    if geometry == nil or controller == nil then return end

    local root = safe(function() return controller:GetRootWidget() end)
    local viewportRoot = root ~= nil and safe(function() return root:GetParentWidget() end) or nil
    if root == nil or viewportRoot == nil then
        print(LOG_PREFIX .. " roots unavailable during " .. reason)
        return
    end

    viewportRoot:SetSize(geometry.viewportWidth, VIEWPORT_HEIGHT)
    viewportRoot:SetMargin(0.0, 0.0, 0.0, 0.0)
    root:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
    root:SetMargin(0.0, 0.0, 0.0, 0.0)

    applyMenuShellLayout(geometry)

    local containers = resizeNamedWidgets(
        root, "EntityPreviewContainer", geometry.viewportWidth, VIEWPORT_HEIGHT
    )
    local previews = resizeNamedWidgets(
        root, "EntityPreview", geometry.viewportWidth, VIEWPORT_HEIGHT
    )
    local spawns = resizeNamedWidgets(
        root, "SpawnContainer", geometry.viewportWidth, VIEWPORT_HEIGHT
    )

    -- District outlines are a 2D overlay authored in the original 3840-wide
    -- coordinate space. Keep that overlay centered instead of stretching it
    -- with the new 5160-wide map canvas; otherwise its error grows with zoom.
    local districtRoots = 0
    local districtInset = (geometry.contentWidth - 3840.0) * 0.5
    for _, widget in ipairs(collectByName(root, "DistrictsRoot", 12)) do
        local ok = pcall(function()
            widget:SetMargin(districtInset, 0.0, districtInset, 0.0)
        end)
        if ok then districtRoots = districtRoots + 1 end
    end

    local gpsPathContainers = 0
    for _, widget in ipairs(collectByName(root, "GPSPathContainer", 12)) do
        local ok = pcall(function()
            widget:SetMargin(districtInset, 0.0, districtInset, 0.0)
        end)
        if ok then gpsPathContainers = gpsPathContainers + 1 end
    end

    debugLog(string.format(
        "%s %s: viewport=%.2fx%.2f root=%.2fx%.2f containers=%d previews=%d spawns=%d districts=%d gpsPaths=%d",
        LOG_PREFIX, reason,
        geometry.viewportWidth, VIEWPORT_HEIGHT,
        geometry.contentWidth, REFERENCE_HEIGHT,
        containers, previews, spawns, districtRoots, gpsPathContainers
    ))
end

local function applyInventoryLayout(controller, reason)
    cancelMainMenuRetries("inventory " .. tostring(reason))
    ensureMenuPillarsDisabled("inventory " .. tostring(reason))
    local geometry = getTargetGeometry()
    if geometry == nil or controller == nil then return end

    local root = safe(function() return controller:GetRootWidget() end)
    if root == nil then
        print(LOG_PREFIX .. " inventory root unavailable during " .. reason)
        return
    end

    -- The controller root is Root1: keep the actual inventory layout at 16:9.
    -- Widen its sibling Root2, which owns the fullscreen background.
    local shellRoot = safe(function() return root:GetParentWidget() end)
    local widenedRoots = 0
    local childCount = shellRoot ~= nil and safe(function()
        return shellRoot:GetNumChildren()
    end) or 0

    for index = 0, childCount - 1 do
        local child = safe(function() return shellRoot:GetWidget(index) end)
        if child ~= nil and widgetName(child) == "Root" then
            local ok = pcall(function()
                child:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
            end)
            if ok then widenedRoots = widenedRoots + 1 end
        end
    end

    -- Restore Root1 after the sibling pass, independently of child ordering.
    root:SetSize(3840.0, REFERENCE_HEIGHT)

    local rightLines = 0
    for _, widget in ipairs(collectByName(shellRoot, "Right_lines", 12)) do
        local ok = pcall(function()
            widget:SetMargin(geometry.contentWidth - 55.0, 0.0, 0.0, 0.0)
        end)
        if ok then rightLines = rightLines + 1 end
    end

    local buttonHints = 0
    for _, widget in ipairs(collectByName(root, "button_hints", 12)) do
        local ok = pcall(function()
            widget:SetMargin(
                50.0, 50.0, extendMarginToEdge(-540.0, geometry), 50.0
            )
        end)
        if ok then buttonHints = buttonHints + 1 end
    end

    local rightFluff = positionRightFluff(shellRoot, geometry, 12)

    debugLog(string.format(
        "%s inventory %s: siblingRoots=%d root1=3840x%.2f root2=%.2fx%.2f rightLines=%d rightFluff=%d buttonHints=%d",
        LOG_PREFIX, reason, widenedRoots, REFERENCE_HEIGHT,
        geometry.contentWidth, REFERENCE_HEIGHT, rightLines, rightFluff, buttonHints
    ))
end

local function getMenuVirtualWindow()
    local layer = safe(function()
        return Game.GetInkSystem():GetLayer(CName.new("inkMenuLayer"))
    end)
    return layer ~= nil and safe(function()
        return layer:GetVirtualWindow()
    end) or nil
end

local function applyCyberwareLayout(controller, reason)
    cancelMainMenuRetries("cyberware " .. tostring(reason))
    ensureMenuPillarsDisabled("cyberware " .. tostring(reason))
    local geometry = getTargetGeometry()
    if geometry == nil or controller == nil then return end

    local searchRoot = getMenuVirtualWindow()
    if searchRoot == nil then return end

    local buttonHints = 0
    for _, widget in ipairs(collectByName(searchRoot, "button_hints", 24)) do
        local ok = pcall(function()
            widget:SetMargin(
                0.0, 0.0, extendMarginToEdge(-540.0, geometry), 50.0
            )
        end)
        if ok then buttonHints = buttonHints + 1 end
    end

    local rightFluff = positionRightFluff(searchRoot, geometry, 24)

    debugLog(string.format(
        "%s cyberware %s: buttonHints=%d rightFluff=%d",
        LOG_PREFIX, reason, buttonHints, rightFluff
    ))
end

local function applyCharacterLayout(controller, reason)
    cancelMainMenuRetries("character " .. tostring(reason))
    ensureMenuPillarsDisabled("character " .. tostring(reason))
    local geometry = getTargetGeometry()
    if geometry == nil or controller == nil then return end

    local searchRoot = getMenuVirtualWindow()
    if searchRoot == nil then return end

    local backgroundInset = (geometry.contentWidth - 3840.0) * 0.5
    local backgrounds = 0
    for _, widget in ipairs(collectByName(searchRoot, "master_BG", 12)) do
        local ok = pcall(function()
            -- master_BG is a tiled Fill widget. Negative horizontal margins
            -- extend its drawing area without resizing its UI parent.
            widget:SetMargin(-backgroundInset, 0.0, -backgroundInset, 0.0)
        end)
        if ok then backgrounds = backgrounds + 1 end
    end

    local buttonHints = 0
    for _, widget in ipairs(collectByName(searchRoot, "button_hints", 24)) do
        local ok = pcall(function()
            widget:SetMargin(
                0.0, 0.0, extendMarginToEdge(-540.0, geometry), 50.0
            )
        end)
        if ok then buttonHints = buttonHints + 1 end
    end

    local rightFluff = positionRightFluff(searchRoot, geometry, 24)

    debugLog(string.format(
        "%s character %s: backgrounds=%d buttonHints=%d rightFluff=%d",
        LOG_PREFIX, reason, backgrounds, buttonHints, rightFluff
    ))
end

local function applyJournalLayout(controller, reason)
    cancelMainMenuRetries("journal " .. tostring(reason))
    ensureMenuPillarsDisabled("journal " .. tostring(reason))
    local geometry = getTargetGeometry()
    if geometry == nil or controller == nil then return end

    local searchRoot = getMenuVirtualWindow()
    if searchRoot == nil then return end

    local buttonHints = 0
    for _, widget in ipairs(collectByName(searchRoot, "button_hints", 24)) do
        local ok = pcall(function()
            widget:SetMargin(
                0.0, 0.0, extendMarginToEdge(-540.0, geometry), 50.0
            )
        end)
        if ok then buttonHints = buttonHints + 1 end
    end

    local rightFluff = positionRightFluff(searchRoot, geometry, 24)

    debugLog(string.format(
        "%s journal %s: buttonHints=%d rightFluff=%d",
        LOG_PREFIX, reason, buttonHints, rightFluff
    ))
end

local function applyStashLayout(_, reason)
    if not stashMenuActive then return false end
    if stashLayoutFinalized then return true end
    cancelMainMenuRetries("stash " .. tostring(reason))
    ensureMenuPillarsDisabled("stash " .. tostring(reason))
    local geometry = getTargetGeometry()
    if geometry == nil then return false end

    -- Exact Ink hierarchy (the Inspector's Root1/Root2 suffixes are indices;
    -- both widgets have the runtime name "Root"):
    -- inkVirtualWindow -> Root -> Root[0, fullscreen_vendor]
    --                              -> wrapper -> wrapper
    --                                 -> playerPanel + vendorPanel
    --                           + Root[1, vendor_hub]
    local virtualWindow = getMenuVirtualWindow()
    local outerRoot = virtualWindow ~= nil and safe(function()
        return virtualWindow:GetWidget(0)
    end) or nil
    if outerRoot == nil or widgetName(outerRoot) ~= "Root" then return false end

    -- Once geometry is stable, retries only wait for the two data sources.
    -- They must not resize/invalidate the visible widgets again.
    if stashGeometryApplied then
        return true
    end

    if STASH_TREE_DIAGNOSTICS and not stashTreeDumped then
        local file = io.open(STASH_TREE_DIAGNOSTIC_FILE, "w")
        if file ~= nil then
            local function text(value)
                return value ~= nil and tostring(value) or "nil"
            end
            local function vector(value)
                return value ~= nil and string.format("%.2f,%.2f", value.X, value.Y) or "nil"
            end
            local function margin(value)
                return value ~= nil and string.format(
                    "%.2f,%.2f,%.2f,%.2f",
                    value.left, value.top, value.right, value.bottom
                ) or "nil"
            end
            local function visit(widget, depth, path)
                if widget == nil or depth > 20 then return end
                local children = safe(function() return widget:GetNumChildren() end) or 0
                file:write(string.format(
                    "%s%s | class=%s children=%d size=%s desired=%s margin=%s padding=%s anchor=%s anchorPoint=%s hAlign=%s vAlign=%s sizeRule=%s scale=%s translation=%s visible=%s opacity=%s\n",
                    string.rep("  ", depth), path,
                    text(safe(function() return widget:GetClassName() end)), children,
                    vector(safe(function() return widget:GetSize() end)),
                    vector(safe(function() return widget:GetDesiredSize() end)),
                    margin(safe(function() return widget:GetMargin() end)),
                    margin(safe(function() return widget:GetPadding() end)),
                    text(safe(function() return widget:GetAnchor() end)),
                    vector(safe(function() return widget:GetAnchorPoint() end)),
                    text(safe(function() return widget:GetHAlign() end)),
                    text(safe(function() return widget:GetVAlign() end)),
                    text(safe(function() return widget:GetSizeRule() end)),
                    vector(safe(function() return widget:GetScale() end)),
                    vector(safe(function() return widget:GetTranslation() end)),
                    text(safe(function() return widget:IsVisible() end)),
                    text(safe(function() return widget:GetOpacity() end)
                )))
                for index = 0, children - 1 do
                    local child = safe(function() return widget:GetWidget(index) end)
                    if child ~= nil then
                        local name = widgetName(child)
                        if name == "" then name = "<unnamed>" end
                        visit(child, depth + 1, string.format("%s/%s[%d]", path, name, index))
                    end
                end
            end
            file:write(string.format("Ultrawide UI Overhaul stash tree dump | %s\n", os.date("%Y-%m-%d %H:%M:%S")))
            visit(outerRoot, 0, "VirtualWindow[0]/Root")
            file:flush()
            file:close()
            stashTreeDumped = true
            print(LOG_PREFIX .. " stash widget tree dumped")
        end
    end

    local widenedRoots = 0
    for index = 0, 1 do
        local child = safe(function() return outerRoot:GetWidget(index) end)
        if child ~= nil and widgetName(child) == "Root" then
            local ok = pcall(function()
                child:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
            end)
            if ok then widenedRoots = widenedRoots + 1 end
        end
    end

    -- Each Stash slot is 224 units wide. Panel width is derived from the
    -- ratio-aware number of complete columns, plus the vanilla 34-unit
    -- scrollbar allowance. Native translations remain animation-owned.
    local slotWidth = 224.0
    -- Scale continuously across the supported range: six vanilla columns at
    -- 16:9, ten at 21:9 and fifteen at 32:9. This gives 2:1 displays a layout
    -- that fits their smaller side extensions without overlapping panels.
    local columnsAt16x9 = 6
    local columnsAt21x9 = 10
    local columnsAt32x9 = 15
    local widthAt16x9 = VANILLA_CONTENT_WIDTH
    local widthAt21x9 = LEGACY_21X9_CONTENT_WIDTH
    local widthAt32x9 = 7680.0
    local targetColumns = columnsAt21x9
    if geometry.contentWidth < widthAt21x9 then
        local narrowProgress = math.max(0.0, math.min(
            1.0,
            (geometry.contentWidth - widthAt16x9) /
            (widthAt21x9 - widthAt16x9)
        ))
        targetColumns = columnsAt16x9 + math.floor(
            narrowProgress * (columnsAt21x9 - columnsAt16x9) + 0.5
        )
    else
        local wideProgress = math.max(0.0, math.min(
            1.0,
            (geometry.contentWidth - widthAt21x9) /
            (widthAt32x9 - widthAt21x9)
        ))
        targetColumns = columnsAt21x9 + math.floor(
            wideProgress * (columnsAt32x9 - columnsAt21x9) + 0.5
        )
    end
    local cachedGridWidth = targetColumns * slotWidth
    local zoneWidth = cachedGridWidth + 34.0
    local zones = 0
    local grids = 0
    for _, zoneName in ipairs({ "playerPanel", "vendorPanel" }) do
        for _, zone in ipairs(collectByName(outerRoot, zoneName, 8)) do
            local zoneSize = safe(function() return zone:GetSize() end)
            if pcall(function()
                zone:SetSize(zoneWidth, zoneSize ~= nil and zoneSize.Y or 0.0)
                -- Keep the final positions previously validated with margins
                -- 635/165 and forced translations -400/+400, but encode the
                -- effective offsets entirely in layout margins. Translation
                -- belongs to the native entrance animation and must remain
                -- under the game's control.
                local panelInset = interpolateToLegacy21x9(
                    0.0, 235.0, geometry
                )
                if zoneName == "playerPanel" then
                    zone:SetMargin(panelInset, 0.0, 0.0, 0.0)
                else
                    zone:SetMargin(0.0, 0.0, -panelInset, 0.0)
                end
            end) then
                zones = zones + 1
                for _, container in ipairs(collectByName(zone, "inventoryContainer", 8)) do
                    local containerSize = safe(function() return container:GetSize() end)
                    pcall(function()
                        container:SetSize(zoneWidth, containerSize ~= nil and containerSize.Y or 0.0)
                    end)
                end
                for _, scrollName in ipairs({ "scroll_area", "scrollArea", "stash_scroll_area_cache", "inventory_scroll_area_cache" }) do
                    for _, scroll in ipairs(collectByName(zone, scrollName, 10)) do
                        local size = safe(function() return scroll:GetSize() end)
                        local scrollWidth = math.max(0.0, zoneWidth - 34.0)
                        pcall(function()
                            scroll:SetSize(scrollWidth, size ~= nil and size.Y or REFERENCE_HEIGHT)
                        end)
                        for _, gridName in ipairs({ "player_virtualgrid", "vendor_virtualgrid" }) do
                            for _, grid in ipairs(collectByName(scroll, gridName, 4)) do
                                local gridSize = safe(function() return grid:GetSize() end)
                                local gridController = safe(function() return grid.logicController end) or
                                    safe(function() return grid:GetController() end)
                                local gridResized = pcall(function()
                                    grid:SetSize(scrollWidth, gridSize ~= nil and gridSize.Y or REFERENCE_HEIGHT)
                                    grid:FlagForVisualInvalidation()
                                end)
                                if gridResized then grids = grids + 1 end
                            end
                        end
                    end
                end
                for _, imageName in ipairs({ "inventoryCacheRT", "stashCacheRT" }) do
                    for _, image in ipairs(collectByName(zone, imageName, 10)) do
                        local imageSize = safe(function() return image:GetSize() end)
                        local imageMargin = safe(function() return image:GetMargin() end)
                        local centerOffset = 0.0
                        if imageSize ~= nil and imageMargin ~= nil then
                            centerOffset = imageMargin.left - imageSize.X * 0.5
                        end
                        pcall(function()
                            image:SetSize(cachedGridWidth, imageSize ~= nil and imageSize.Y or REFERENCE_HEIGHT)
                            image:SetMargin(
                                cachedGridWidth * 0.5 + centerOffset,
                                imageMargin ~= nil and imageMargin.top or 0.0,
                                imageMargin ~= nil and imageMargin.right or 0.0,
                                imageMargin ~= nil and imageMargin.bottom or 0.0
                            )
                            image:FlagForVisualInvalidation()
                        end)
                    end
                end
                for _, imageName in ipairs({ "inkImageWidget2a", "inkImageWidget2" }) do
                    for _, image in ipairs(collectByName(zone, imageName, 10)) do
                        local imageSize = safe(function() return image:GetSize() end)
                        pcall(function()
                            image:SetSize(cachedGridWidth, imageSize ~= nil and imageSize.Y or REFERENCE_HEIGHT)
                            image:FlagForVisualInvalidation()
                        end)
                    end
                end
                for _, cacheName in ipairs({ "inventory_scroll_area_cache", "stash_scroll_area_cache" }) do
                    for _, cache in ipairs(collectByName(zone, cacheName, 10)) do
                        pcall(function() cache:FlagForVisualInvalidation() end)
                    end
                end
                for _, filters in ipairs(collectByName(zone, "filtersContainer", 8)) do
                    pcall(function()
                        filters:SetWrappingWidgetCount(8)
                        filters:FlagForVisualInvalidation()
                    end)
                end
                for _, searchName in ipairs({ "searchContainerPlayer", "searchContainerStorage" }) do
                    for _, searchContainer in ipairs(collectByName(zone, searchName, 8)) do
                        pcall(function()
                            searchContainer:SetHAlign(inkEHorizontalAlign.Right)
                            searchContainer:SetMargin(0.0, -90.0, 1060.0, 50.0)
                            searchContainer:FlagForVisualInvalidation()
                        end)
                    end
                end
            end
        end
    end

    if STASH_CONTROLLER_DIAGNOSTICS and not stashControllerDumped then
        local file = io.open(STASH_CONTROLLER_DIAGNOSTIC_FILE, "w")
        if file ~= nil then
            file:write(string.format(
                "Ultrawide UI Overhaul stash controller dump | %s\n",
                os.date("%Y-%m-%d %H:%M:%S")
            ))
            local function dumpControllers(label, widgets)
                for index, widget in ipairs(widgets) do
                    local controller = safe(function() return widget.logicController end) or
                        safe(function() return widget:GetController() end)
                    local dump = safe(function() return GameDump(controller) end)
                    file:write(string.format(
                        "\n[%s #%d] widgetClass=%s controllerClass=%s\n%s\n",
                        label, index,
                        tostring(safe(function() return widget:GetClassName() end)),
                        tostring(safe(function() return controller:GetClassName() end)),
                        dump ~= nil and tostring(dump) or "controller unavailable or GameDump failed"
                    ))
                end
            end
            dumpControllers("content Root", { safe(function() return outerRoot:GetWidget(0) end) })
            for _, name in ipairs({
                "playerPanel", "vendorPanel", "inventoryContainer",
                "player_virtualgrid", "vendor_virtualgrid"
            }) do
                dumpControllers(name, collectByName(outerRoot, name, 12))
            end
            file:flush()
            file:close()
            stashControllerDumped = true
        end
    end

    debugLog(string.format(
        "%s stash %s: directRoots=%d zones=%d grids=%d columns=%d zoneWidth=%.2f width=%.2f",
        LOG_PREFIX, reason, widenedRoots, zones, grids,
        targetColumns, zoneWidth, geometry.contentWidth
    ))
    local complete = widenedRoots == 2 and zones == 2 and grids >= 2
    -- BeforeOnInitialize establishes the geometry used by the virtual-grid
    -- controllers. Finalize only on the post-initialize pass (or a retry),
    -- after which every remaining scheduled retry becomes a harmless no-op.
    if complete and reason ~= "BeforeOnInitialize" then
        stashGeometryApplied = true
        stashLayoutFinalized = true
    end
    return complete
end

local function refreshStashDataViews(controller)
    if stashDataViewsRefreshed then return true end
    if controller == nil then return false end
    local refreshed = 0
    local virtualWindow = getMenuVirtualWindow()
    local outerRoot = virtualWindow ~= nil and safe(function()
        return virtualWindow:GetWidget(0)
    end) or nil
    if outerRoot == nil then return false end

    for _, entry in ipairs({
        { zone = "playerPanel", callback = "OnPlayerFilterChange" },
        { zone = "vendorPanel", callback = "OnVendorFilterChange" }
    }) do
        local zone = collectByName(outerRoot, entry.zone, 8)[1]
        local filters = zone ~= nil and collectByName(zone, "filtersContainer", 8)[1] or nil
        local radioGroup = filters ~= nil and (
            safe(function() return filters.logicController end) or
            safe(function() return filters:GetController() end)
        ) or nil
        if filters ~= nil then
            pcall(function()
                filters:SetWrappingWidgetCount(8)
                filters:FlagForVisualInvalidation()
            end)
        end
        local selectedIndex = radioGroup ~= nil and (
            safe(function() return radioGroup:GetSelectedIndex() end) or
            safe(function() return radioGroup.selectedIndex end)
        ) or nil
        if radioGroup ~= nil and selectedIndex ~= nil then
            local ok = pcall(function()
                -- Run the complete native filter callback with the already
                -- selected index. This refreshes all data/layout state without
                -- visibly changing the active filter.
                controller[entry.callback](controller, radioGroup, selectedIndex)
            end)
            if ok then refreshed = refreshed + 1 end
        end
    end
    stashDataViewsRefreshed = refreshed == 2
    if STASH_CONTROLLER_DIAGNOSTICS then
        local file = io.open(STASH_CONTROLLER_DIAGNOSTIC_FILE, "a")
        if file ~= nil then
            file:write(string.format(
                "\nfilter callback refresh: refreshed=%d success=%s time=%s\n",
                refreshed, tostring(stashDataViewsRefreshed), os.date("%H:%M:%S")
            ))
            file:flush()
            file:close()
        end
    end
    return stashDataViewsRefreshed
end

local function positionStashSortingDropdown(zoneName, reason)
    if not stashMenuActive then return false end

    local geometry = getTargetGeometry()
    local virtualWindow = getMenuVirtualWindow()
    local outerRoot = virtualWindow ~= nil and safe(function()
        return virtualWindow:GetWidget(0)
    end) or nil
    local contentRoot = outerRoot ~= nil and safe(function()
        return outerRoot:GetWidget(0)
    end) or nil
    if geometry == nil or contentRoot == nil then return false end

    local zone = collectByName(contentRoot, zoneName, 8)[1]
    local button = zone ~= nil and collectByName(zone, "dropdownButton5", 8)[1] or nil
    local dropdown = collectByName(contentRoot, "dropdownContainer", 3)[1]
    if button == nil or dropdown == nil then return false end

    local rootRect = safe(function() return GetScreenPosition(contentRoot) end)
    local buttonRect = safe(function() return GetScreenPosition(button) end)
    if rootRect == nil or buttonRect == nil then return false end

    local rootScreenWidth = rootRect.Right - rootRect.Left
    local rootScreenHeight = rootRect.Bottom - rootRect.Top
    if rootScreenWidth <= 0.0 or rootScreenHeight <= 0.0 then return false end

    -- The vanilla callbacks use fixed 16:9 translations. Convert the actual
    -- on-screen button rectangle back into this widened Root's Ink space so
    -- the shared popup follows either Sort button at every supported ratio.
    local targetX = (buttonRect.Left - rootRect.Left) *
        geometry.contentWidth / rootScreenWidth
    local targetY = (buttonRect.Bottom - rootRect.Top) *
        REFERENCE_HEIGHT / rootScreenHeight

    -- Translation is added to the dropdown's fixed 300x300 layout slot; it is
    -- not an absolute Root-space position. Compensate that stable Ink origin.
    -- Do not infer it from the rendered rectangle: this callback may run more
    -- than once for one interaction, which would feed our own transform back
    -- into the next calculation.
    local baseX = 300.0
    local baseY = 300.0
    local x = targetX - baseX
    local y = targetY - baseY

    local positioned = pcall(function()
        dropdown:SetTranslation(Vector2.new({ X = x, Y = y }))
        dropdown:FlagForVisualInvalidation()
    end)

    if STASH_CONTROLLER_DIAGNOSTICS then
        local file = io.open(STASH_CONTROLLER_DIAGNOSTIC_FILE, "a")
        if file ~= nil then
            file:write(string.format(
                "\ndropdown %s (%s): positioned=%s translation=%.2f,%.2f target=%.2f,%.2f base=%.2f,%.2f buttonScreen=%.2f,%.2f,%.2f,%.2f rootScreen=%.2f,%.2f,%.2f,%.2f time=%s\n",
                zoneName, tostring(reason), tostring(positioned), x, y,
                targetX, targetY, baseX, baseY,
                buttonRect.Left, buttonRect.Top, buttonRect.Right, buttonRect.Bottom,
                rootRect.Left, rootRect.Top, rootRect.Right, rootRect.Bottom,
                os.date("%H:%M:%S")
            ))
            file:flush()
            file:close()
        end
    end

    return positioned
end

local function applyDatabaseLayout(controller, reason)
    cancelMainMenuRetries("database " .. tostring(reason))
    ensureMenuPillarsDisabled("database " .. tostring(reason))
    local geometry = getTargetGeometry()
    if geometry == nil or controller == nil then return end

    local searchRoot = getMenuVirtualWindow()
    if searchRoot == nil then return end

    for _, widget in ipairs(collectByName(searchRoot, "button_hints", 24)) do
        pcall(function()
            widget:SetMargin(
                0.0, 0.0, extendMarginToEdge(-540.0, geometry), 50.0
            )
        end)
    end
end

local function positionBackpackSearch(controller, reason)
    local geometry = getTargetGeometry()
    if geometry == nil or controller == nil then return 0 end

    local searchRoot = getMenuVirtualWindow()
    if searchRoot == nil then
        backpackLifecycleLog(
            "search positioning aborted: inkMenuLayer virtual window unavailable"
        )
        return 0
    end

    local positioned = 0
    for _, wrapper in ipairs(collectByName(searchRoot, "wrapper", 24)) do
        for _, canvas in ipairs(
            collectByName(wrapper, "inkCanvasWidget21", 8)
        ) do
            local filterButtons = collectByName(
                canvas, "filter_buttons", 4
            )[1]
            for _, searchContainer in ipairs(
                collectByName(canvas, "searchContainer", 5)
            ) do
                dumpBackpackRmkSearch(searchContainer)
                if filterButtons ~= nil then
                    local searchOk = pcall(function()
                        local currentParent = searchContainer:GetParentWidget()
                        local searchIndex = -1
                        local dropdownIndex = -1
                        local childCount = filterButtons:GetNumChildren()
                        for index = 0, childCount - 1 do
                            local child = filterButtons:GetWidget(index)
                            if child == searchContainer then
                                searchIndex = index
                            elseif widgetName(child) == "dropdownButton8" then
                                dropdownIndex = index
                            end
                        end

                        if dropdownIndex >= 0 and
                            (currentParent ~= filterButtons or
                             searchIndex ~= dropdownIndex - 1) then
                            local targetIndex = dropdownIndex
                            if currentParent == filterButtons and
                                searchIndex >= 0 and searchIndex < dropdownIndex then
                                targetIndex = dropdownIndex - 1
                            end
                            searchContainer:Reparent(filterButtons, targetIndex)
                        elseif currentParent ~= filterButtons then
                            searchContainer:Reparent(filterButtons, -1)
                        end
                        searchContainer:SetMargin(0.0, 0.0, 0.0, 0.0)
                        searchContainer:SetSize(620.0, 80.0)
                        searchContainer:FlagForVisualInvalidation()
                    end)
                    if searchOk then positioned = positioned + 1 end
                end
            end
        end
    end

    backpackLifecycleLog(string.format(
        "search positioning completed: reason=%s positioned=%d",
        tostring(reason), positioned
    ))
    return positioned
end

local function applyBackpackLayout(controller, reason)
    cancelMainMenuRetries("backpack " .. tostring(reason))
    ensureMenuPillarsDisabled("backpack " .. tostring(reason))
    if not BACKPACK_LAYOUT_ENABLED then
        debugLog(LOG_PREFIX .. " Backpack Safe Mode active; expanded layout skipped")
        backpackLifecycleLog("expanded layout skipped by safe mode")
        return
    end
    local geometry = getTargetGeometry()
    if geometry == nil or controller == nil then
        backpackLifecycleLog(string.format(
            "application aborted: reason=%s controller=%s geometry=%s",
            tostring(reason), tostring(controller), tostring(geometry)
        ))
        return
    end
    if backpackLayoutAppliedControllers[controller] then
        backpackLifecycleLog(
            "duplicate application rejected: reason=" .. tostring(reason)
        )
        return
    end

    local searchRoot = getMenuVirtualWindow()
    if searchRoot == nil then
        backpackLifecycleLog(
            "application aborted: inkMenuLayer virtual window unavailable"
        )
        return
    end
    backpackLayoutAppliedControllers[controller] = true
    backpackLifecycleLog(string.format(
        "single application started: reason=%s controller=%s width=%.2f",
        tostring(reason), tostring(controller), geometry.contentWidth
    ))

    local widenedRoots = 0
    local widenedInventoryCanvases = 0
    local inventoryCanvasWidth = extendLegacy21x9Value(
        2720.0, 3990.0, geometry
    )
    for _, wrapper in ipairs(collectByName(searchRoot, "wrapper", 24)) do
        local parent = safe(function() return wrapper:GetParentWidget() end)
        if parent ~= nil and widgetName(parent) == "Root" then
            local ok = pcall(function()
                -- Backpack's second Root owns wrapper and the item-grid area.
                -- Widen only this branch; the other Root keeps the vanilla
                -- coordinate space used by the rest of the screen.
                parent:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
            end)
            if ok then widenedRoots = widenedRoots + 1 end
        end

        for _, canvas in ipairs(
            collectByName(wrapper, "inkCanvasWidget21", 8)
        ) do
            local ok = pcall(function()
                local size = canvas:GetSize()
                canvas:SetSize(inventoryCanvasWidth, size.Y)
                canvas:FlagForVisualInvalidation()
            end)
            if ok then
                widenedInventoryCanvases = widenedInventoryCanvases + 1
            end

        end
    end

    local expandedGridColumns = 0
    local additionalGridWidth = 0.0
    for _, inventoryWrapper in ipairs(
        collectByName(searchRoot, "inventory_wrapper", 24)
    ) do
        dumpBackpackControllers(controller, inventoryWrapper)

        for _, virtualGrid in ipairs(
            collectByName(inventoryWrapper, "inkVirtualCompoundWidget4", 12)
        ) do
            local gridController = safe(function()
                return virtualGrid.logicController
            end) or safe(function()
                return virtualGrid:GetController()
            end)
            local slotSize = safe(function() return gridController.slotSize end)
            local slotWidth = slotSize ~= nil and slotSize.X or 222.0
            local availableWidth = math.max(
                0.0,
                geometry.contentWidth - 3840.0
            )
            -- Backpack is aligned to the new left edge, so its grid can use
            -- the complete width added beyond the original 16:9 canvas. At
            -- 21:9 this is 1320 INK units, i.e. six additional 222-unit
            -- columns after normal layout rounding.
            local additionalColumns = math.floor(
                availableWidth / slotWidth + 0.5
            )
            local targetColumns = 12 + additionalColumns
            local usedWidth = additionalColumns * slotWidth

            local ok = pcall(function()
                gridController.width = targetColumns
                virtualGrid:SetSize(1800.0 + usedWidth, 1800.0)
                virtualGrid:FlagForVisualInvalidation()
            end)
            if ok then
                expandedGridColumns = targetColumns
                additionalGridWidth = usedWidth
            end
        end

        if additionalGridWidth > 0.0 then
            local widthByName = {
                scroll_cache_widget = 2720.0,
                scroll_area = 2720.0,
                ScrollCacheImage = 2740.0,
                scrollingBackground = 1800.0,
                scrollingBackgroundshadow = 1800.0,
                inkCanvasWidget16 = 2740.0
            }
            for name, vanillaWidth in pairs(widthByName) do
                for _, widget in ipairs(collectByName(inventoryWrapper, name, 12)) do
                    pcall(function()
                        local size = widget:GetSize()
                        widget:SetSize(vanillaWidth + additionalGridWidth, size.Y)
                        widget:FlagForVisualInvalidation()
                    end)
                end
            end
        end
    end

    if not backpackTreeDumped then
        for _, inventoryWrapper in ipairs(collectByName(searchRoot, "inventory_wrapper", 24)) do
            local parent = safe(function() return inventoryWrapper:GetParentWidget() end)
            if parent ~= nil and widgetName(parent) == "wrapper" then
                dumpBackpackWidgetTree(inventoryWrapper)
                break
            end
        end
    end

    local buttonHints = 0
    for _, widget in ipairs(collectByName(searchRoot, "button_hints", 24)) do
        local ok = pcall(function()
            widget:SetMargin(0.0, 0.0, 120.0, 50.0)
        end)
        if ok then buttonHints = buttonHints + 1 end
    end

    local dropdownContainers = 0
    local dropdownLeft = extendLegacy21x9Value(
        2879.0, 4146.0, geometry
    )
    for _, widget in ipairs(
        collectByName(searchRoot, "dropdownContainer", 24)
    ) do
        local parent = safe(function() return widget:GetParentWidget() end)
        local grandParent = parent ~= nil and safe(function()
            return parent:GetParentWidget()
        end) or nil
        if parent ~= nil and grandParent ~= nil and
            widgetName(parent) == "Root" and widgetName(grandParent) == "Root" then
            local ok = pcall(function()
                widget:SetMargin(dropdownLeft, 188.0, 0.0, 0.0)
                widget:FlagForVisualInvalidation()
            end)
            if ok then dropdownContainers = dropdownContainers + 1 end
        end
    end

    local rightFluff = positionRightFluff(searchRoot, geometry, 24)

    debugLog(string.format(
        "%s backpack %s: widenedRoots=%d inventoryCanvases=%d canvasWidth=%.2f rmkSearch=%d gridColumns=%d gridExtraWidth=%.2f buttonHints=%d dropdowns=%d dropdownLeft=%.2f rightFluff=%d",
        LOG_PREFIX, reason, widenedRoots, widenedInventoryCanvases,
        inventoryCanvasWidth, 0,
        expandedGridColumns, additionalGridWidth, buttonHints,
        dropdownContainers, dropdownLeft, rightFluff
    ))
    backpackLifecycleLog(string.format(
        "single application completed: roots=%d canvases=%d gridColumns=%d gridExtraWidth=%.2f rmkSearch=%d dropdowns=%d",
        widenedRoots, widenedInventoryCanvases, expandedGridColumns,
        additionalGridWidth, 0,
        dropdownContainers
    ))
end

local function resizeRevisedBackpackItemRow(controller)
    if controller == nil then return 0 end
    local geometry = getTargetGeometry()
    if geometry == nil then return 0 end
    local root = safe(function() return controller:GetRootWidget() end)
    if root == nil then return 0 end

    local nameContainerWidth = interpolateToLegacy21x9(
        772.0, 1242.0, geometry
    )
    local nameTextWidth = interpolateToLegacy21x9(
        640.0, 1110.0, geometry
    )
    local typeWidth = interpolateToLegacy21x9(418.0, 718.0, geometry)
    local rowEffectWidth = interpolateToLegacy21x9(
        3840.0, 5200.0, geometry
    )
    local rowEffectMargin = interpolateToLegacy21x9(
        0.0, -1000.0, geometry
    )
    local selectionWidth = interpolateToLegacy21x9(
        2088.0, 2988.0, geometry
    )

    local resized = 0
    -- RevisedBackpackItemController resolves these as
    -- item/nameContainer and item/type. They are deliberately handled when
    -- each virtual row is created instead of scanning the current list pool.
    for _, widget in ipairs(collectByName(root, "nameContainer", 4)) do
        local ok = pcall(function()
            local size = widget:GetSize()
            widget:SetSize(
                nameContainerWidth, size ~= nil and size.Y or 80.0
            )
            widget:FlagForVisualInvalidation()

            -- The text keeps its own vanilla wrapping boundary even when its
            -- parent cell grows. Widen it explicitly and keep names one-line.
            for _, nameText in ipairs(collectByName(widget, "name", 2)) do
                local textSize = nameText:GetSize()
                nameText:SetSize(
                    nameTextWidth, textSize ~= nil and textSize.Y or 80.0
                )
                nameText:SetWrapping(
                    false, nameTextWidth, textWrappingPolicy.Default
                )
                nameText:SetWrappingAtPosition(nameTextWidth)
                nameText:FlagForVisualInvalidation()
            end
        end)
        if ok then resized = resized + 1 end
    end
    for _, widget in ipairs(collectByName(root, "type", 4)) do
        local ok = pcall(function()
            local size = widget:GetSize()
            widget:SetSize(typeWidth, size ~= nil and size.Y or 80.0)
            -- Update the text layout boundary as well as the widget box, or
            -- the vanilla 418-wide ellipsis remains cached.
            widget:SetWrapping(false, typeWidth, textWrappingPolicy.Default)
            widget:SetWrappingAtPosition(typeWidth)
            widget:FlagForVisualInvalidation()
        end)
        if ok then resized = resized + 1 end
    end
    for _, widget in ipairs(collectByName(root, "shadow", 4)) do
        local ok = pcall(function()
            widget:SetMargin(rowEffectMargin, 0.0, 0.0, 0.0)
            widget:SetSize(rowEffectWidth, 80.0)
            widget:SetOpacity(0.03)
            widget:FlagForVisualInvalidation()
        end)
        if ok then resized = resized + 1 end
    end
    for _, widget in ipairs(collectByName(root, "selection", 4)) do
        local ok = pcall(function()
            widget:SetSize(selectionWidth, 80.0)
            widget:FlagForVisualInvalidation()
        end)
        if ok then resized = resized + 1 end
    end
    return resized
end

local function applyRevisedBackpackLayout(controller, reason)
    cancelMainMenuRetries("revised backpack " .. tostring(reason))
    ensureMenuPillarsDisabled("revised backpack " .. tostring(reason))
    local geometry = getTargetGeometry()
    if geometry == nil or controller == nil then return end

    -- Revised Backpack works best as one cohesive table/preview layout. Keep
    -- its validated 21:9 composition on wider displays instead of pushing the
    -- preview all the way to the physical right edge.
    local layoutWidth = math.min(geometry.contentWidth, LEGACY_21X9_CONTENT_WIDTH)
    local headerNameWidth = interpolateToLegacy21x9(
        772.0, 1272.0, geometry
    )
    local typeWidth = interpolateToLegacy21x9(418.0, 718.0, geometry)
    local selectedItemsRight = interpolateToLegacy21x9(
        1080.0, 1980.0, geometry
    )
    -- Narrower-than-21:9 layouts need proportionally smaller previews so the
    -- table and preview do not overlap. Give exact 2:1 layouts a ten-percent
    -- visual boost, then taper it back to the validated size at 21:9. The
    -- boost is also zero at vanilla width and remains capped for every ratio
    -- wider than 21:9.
    local narrowProgress = math.max(0.0, math.min(
        1.0,
        (geometry.contentWidth - VANILLA_CONTENT_WIDTH) /
        (LEGACY_21X9_CONTENT_WIDTH - VANILLA_CONTENT_WIDTH)
    ))
    local twoToOneProgress =
        (2.0 * REFERENCE_HEIGHT - VANILLA_CONTENT_WIDTH) /
        (LEGACY_21X9_CONTENT_WIDTH - VANILLA_CONTENT_WIDTH)
    local previewBoost = 1.0
    if narrowProgress <= twoToOneProgress then
        previewBoost = 1.0 + 0.10 * narrowProgress / twoToOneProgress
    elseif narrowProgress < 1.0 then
        previewBoost = 1.0 + 0.10 *
            (1.0 - narrowProgress) / (1.0 - twoToOneProgress)
    end

    -- interpolateToLegacy21x9 itself is capped at 1.0, therefore 21:9 and
    -- every wider ratio retain the exact validated 21:9 preview sizes.
    local garmentPreviewSize = interpolateToLegacy21x9(
        1395.0, 1895.0, geometry
    ) * previewBoost
    local garmentPreviewTop = 120.0
    local itemPreviewWidth = interpolateToLegacy21x9(
        1395.0, 1995.0, geometry
    ) * previewBoost
    local itemPreviewHeight = interpolateToLegacy21x9(
        930.0, 1330.0, geometry
    ) * previewBoost
    local itemPreviewTop = 400.0

    -- Revised Backpack owns this controller, so its root is specifically the
    -- library Root at Name Path Root/Root in revised_backpack.inkwidget.
    -- No vanilla Backpack widget is touched by this compatibility path.
    local root = safe(function() return controller:GetRootWidget() end)
    if root == nil then return end

    local ok = pcall(function()
        root:SetSize(layoutWidth, REFERENCE_HEIGHT)
        root:SetMargin(0.0, 0.0, 0.0, 0.0)
        root:FlagForVisualInvalidation()
    end)

    -- Header cells are direct children at Root/Root. Item rows use different
    -- paths and are handled by RevisedBackpackItemController.OnInitialize.
    local nameColumns = 0
    for _, widget in ipairs(collectByName(root, "nameContainer", 16)) do
        local parent = safe(function() return widget:GetParentWidget() end)
        if parent == nil or widgetName(parent) ~= "item" then
            local resized = pcall(function()
                local size = widget:GetSize()
                widget:SetSize(
                    headerNameWidth, size ~= nil and size.Y or 80.0
                )
                widget:FlagForVisualInvalidation()
            end)
            if resized then nameColumns = nameColumns + 1 end
        end
    end

    local typeColumns = 0
    for _, widget in ipairs(collectByName(root, "typeContainer", 16)) do
        local resized = pcall(function()
            local size = widget:GetSize()
            widget:SetSize(typeWidth, size ~= nil and size.Y or 80.0)
            widget:FlagForVisualInvalidation()
        end)
        if resized then typeColumns = typeColumns + 1 end
    end

    local scrollAreas = 0
    local scrollAreaWidth = 2188.0 + math.max(
        0.0,
        layoutWidth - 3840.0
    ) * (900.0 / 1320.0)
    for _, widget in ipairs(collectByName(root, "scrollArea", 12)) do
        local resized = pcall(function()
            local size = widget:GetSize()
            widget:SetSize(scrollAreaWidth, size ~= nil and size.Y or 1400.0)
            widget:FlagForVisualInvalidation()
        end)
        if resized then scrollAreas = scrollAreas + 1 end
    end

    for _, widget in ipairs(collectByName(root, "selectedItemsCount", 12)) do
        pcall(function()
            widget:SetMargin(0.0, 440.0, selectedItemsRight, 0.0)
            widget:FlagForVisualInvalidation()
        end)
    end

    for _, previewGarment in ipairs(collectByName(root, "previewGarment", 12)) do
        pcall(function()
            previewGarment:SetSize(garmentPreviewSize, garmentPreviewSize)
            previewGarment:SetMargin(0.0, garmentPreviewTop, 0.0, 0.0)
            previewGarment:FlagForVisualInvalidation()
        end)
        for _, rootName in ipairs({ "root", "Root" }) do
            for _, previewRoot in ipairs(collectByName(previewGarment, rootName, 4)) do
                pcall(function()
                    previewRoot:SetSize(garmentPreviewSize, garmentPreviewSize)
                    previewRoot:SetMargin(0.0, 0.0, 0.0, 0.0)
                    previewRoot:FlagForVisualInvalidation()
                end)
            end
        end
        for _, wrapper in ipairs(collectByName(previewGarment, "wrapper", 4)) do
            pcall(function()
                wrapper:SetSize(garmentPreviewSize, garmentPreviewSize)
                wrapper:SetMargin(0.0, 0.0, 0.0, 0.0)
                wrapper:FlagForVisualInvalidation()
            end)
        end
        for _, preview in ipairs(collectByName(previewGarment, "preview", 4)) do
            pcall(function()
                preview:SetSize(garmentPreviewSize, garmentPreviewSize)
                preview:SetMargin(0.0, 0.0, 0.0, 0.0)
                preview:FlagForVisualInvalidation()
            end)
        end
    end

    for _, previewItem in ipairs(collectByName(root, "previewItem", 12)) do
        pcall(function()
            previewItem:SetSize(itemPreviewWidth, itemPreviewHeight)
            previewItem:SetMargin(0.0, itemPreviewTop, 0.0, 0.0)
            previewItem:FlagForVisualInvalidation()
        end)
        for _, rootName in ipairs({ "root", "Root" }) do
            for _, previewRoot in ipairs(collectByName(previewItem, rootName, 4)) do
                pcall(function()
                    previewRoot:SetSize(itemPreviewWidth, itemPreviewHeight)
                    previewRoot:SetMargin(0.0, 0.0, 0.0, 0.0)
                    previewRoot:FlagForVisualInvalidation()
                end)
            end
        end
        for _, wrapper in ipairs(collectByName(previewItem, "wrapper", 4)) do
            pcall(function()
                wrapper:SetSize(itemPreviewWidth, itemPreviewHeight)
                wrapper:SetMargin(0.0, 0.0, 0.0, 0.0)
                wrapper:FlagForVisualInvalidation()
            end)
        end
        for _, preview in ipairs(collectByName(previewItem, "preview", 4)) do
            pcall(function()
                preview:SetSize(itemPreviewWidth, itemPreviewHeight)
                preview:SetMargin(0.0, 0.0, 0.0, 0.0)
                preview:FlagForVisualInvalidation()
            end)
        end
    end

    debugLog(string.format(
        "%s revised backpack %s: root=%s screenWidth=%.2f layoutWidth=%.2f nameColumns=%d typeColumns=%d scrollAreas=%d scrollAreaWidth=%.2f",
        LOG_PREFIX, reason, tostring(ok), geometry.contentWidth, layoutWidth,
        nameColumns, typeColumns, scrollAreas, scrollAreaWidth
    ))
end

local function applyAuxiliaryMenuLayout(controller, reason, menuLabel, hintWidgetName)
    cancelMainMenuRetries(tostring(menuLabel) .. " " .. tostring(reason))
    ensureMenuPillarsDisabled(tostring(menuLabel) .. " " .. tostring(reason))
    local geometry = getTargetGeometry()
    if geometry == nil or controller == nil then return end

    local searchRoot = getMenuVirtualWindow()
    if searchRoot == nil then return end

    local craftingRoots = 0
    local craftingPanels = 0
    local craftingGridWidgets = 0
    local craftingGridRebuilt = false
    local shardsRoots = 0
    local shardsEntryViews = 0
    if menuLabel == "crafting" then
        -- Path: Root/Root/<target Root>/tabs. Only widen the direct parent of
        -- tabs; the sibling Root layers retain their vanilla geometry.
        for _, tabs in ipairs(collectByName(searchRoot, "tabs", 24)) do
            local parent = safe(function() return tabs:GetParentWidget() end)
            local grandParent = parent ~= nil and safe(function()
                return parent:GetParentWidget()
            end) or nil
            if parent ~= nil and grandParent ~= nil and
                widgetName(parent) == "Root" and
                widgetName(grandParent) == "Root" then
                local ok = pcall(function()
                    parent:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
                    parent:FlagForVisualInvalidation()
                end)
                if ok then craftingRoots = craftingRoots + 1 end
            end
        end

        -- Temporary one-shot development dump. The delayed layout pass also
        -- reaches this block, so asynchronously populated children are caught.
        for _, panel in ipairs(collectByName(searchRoot, "craftingPanel", 24)) do
            craftingPanels = craftingPanels + 1
            local resized, rebuilt = applyCraftingGridLayout(panel, geometry)
            craftingGridWidgets = craftingGridWidgets + resized
            craftingGridRebuilt = craftingGridRebuilt or rebuilt
            dumpCraftingWidgetTree(panel)
            dumpCraftingControllers(controller, panel)
        end
    end

    if menuLabel == "shards" then
        -- Path: Root/Root/list_wrapper. Widen only the Root that directly
        -- owns the shard list and entry view.
        for _, listWrapper in ipairs(collectByName(searchRoot, "list_wrapper", 24)) do
            local parent = safe(function() return listWrapper:GetParentWidget() end)
            local grandParent = parent ~= nil and safe(function()
                return parent:GetParentWidget()
            end) or nil
            if parent ~= nil and grandParent ~= nil and
               widgetName(parent) == "Root" and
               widgetName(grandParent) == "Root" then
                local ok = pcall(function()
                    parent:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
                    parent:FlagForVisualInvalidation()
                end)
                if ok then shardsRoots = shardsRoots + 1 end
            end
        end

        for _, entryView in ipairs(collectByName(searchRoot, "entryView", 24)) do
            shardsEntryViews = shardsEntryViews + 1
            -- entryView starts at X=1650. Keep the vanilla 210-unit reserve
            -- on the right and consume everything in between: 3300 INK units
            -- (2200 physical pixels at 3440x1440) on the 21:9 reference.
            local entryWidth = math.max(2000.0, geometry.contentWidth - 1860.0)
            pcall(function()
                entryView:SetSize(entryWidth, 1600.0)
                entryView:FlagForVisualInvalidation()
            end)

            for _, line in ipairs(collectByName(entryView, "line2", 4)) do
                pcall(function()
                    line:SetSize(entryWidth - 80.0, 2.0)
                    line:FlagForVisualInvalidation()
                end)
            end

            for _, scrollArea in ipairs(
                collectByName(entryView, "EntryScrollArea", 4)
            ) do
                pcall(function()
                    scrollArea:SetSize(entryWidth - 175.0, 1600.0)
                    scrollArea:FlagForVisualInvalidation()
                end)

                for _, text in ipairs(collectByName(scrollArea, "text", 4)) do
                    local parent = safe(function() return text:GetParentWidget() end)
                    if parent ~= nil and widgetName(parent) == "container" then
                        pcall(function()
                            local textWidth = entryWidth - 400.0
                            text:SetSize(textWidth, 1600.0)
                            text:SetWrapping(
                                false, textWidth, textWrappingPolicy.Default
                            )
                            text:SetWrappingAtPosition(textWidth)
                            text:FlagForVisualInvalidation()
                        end)
                    end
                end
            end

            dumpShardsEntryViewTree(entryView)
        end
    end

    local buttonHints = 0
    for _, widget in ipairs(collectByName(searchRoot, hintWidgetName, 24)) do
        local ok = pcall(function()
            if menuLabel == "crafting" then
                -- Crafting's widened Root already carries this widget to the
                -- ultrawide edge; retain its vanilla inset.
                widget:SetMargin(0.0, 0.0, 120.0, 50.0)
            elseif menuLabel == "shards" then
                -- Shards' widened Root naturally carries its button hints;
                -- restore the vanilla right inset for this screen only.
                widget:SetMargin(0.0, 0.0, 200.0, 50.0)
            else
                widget:SetMargin(
                    0.0, 0.0, extendMarginToEdge(-540.0, geometry), 50.0
                )
            end
        end)
        if ok then buttonHints = buttonHints + 1 end
    end

    local rightFluff = positionRightFluff(searchRoot, geometry, 24)
    debugLog(string.format(
        "%s %s %s: %s=%d rightFluff=%d craftingRoots=%d craftingPanels=%d craftingGridWidgets=%d craftingGridRebuilt=%s shardsRoots=%d shardsEntryViews=%d",
        LOG_PREFIX, menuLabel, reason, hintWidgetName, buttonHints, rightFluff,
        craftingRoots, craftingPanels, craftingGridWidgets,
        tostring(craftingGridRebuilt), shardsRoots, shardsEntryViews
    ))
end

local function applyGalleryLayout(controller, reason)
    cancelMainMenuRetries("gallery " .. tostring(reason))
    ensureMenuPillarsDisabled("gallery " .. tostring(reason))
    local geometry = getTargetGeometry()
    if geometry == nil or controller == nil then return end

    local searchRoot = getMenuVirtualWindow()
    if searchRoot == nil then return end

    -- The Gallery grid is top-left packed rather than content-centered. Below
    -- 21:9, extrapolating contentWidth - 500 makes the five-column 2:1 grid
    -- too wide and shifts its visible photos left. Interpolate from the
    -- validated 3320 width at 2:1 to 4660 at 21:9, then keep carrying all
    -- additional width through the wider ratios as before.
    local screenshotsWidth = geometry.contentWidth - 500.0
    if geometry.contentWidth < LEGACY_21X9_CONTENT_WIDTH then
        local twoToOneWidth = 2.0 * REFERENCE_HEIGHT
        local narrowProgress = math.max(0.0, math.min(
            1.0,
            (geometry.contentWidth - twoToOneWidth) /
            (LEGACY_21X9_CONTENT_WIDTH - twoToOneWidth)
        ))
        screenshotsWidth = 3320.0 + (4660.0 - 3320.0) * narrowProgress
    end
    -- inkGridWidget has no content-justification property: its cells are
    -- packed from the top-left. Compensate progressively for the additional
    -- 32:9 space while preserving the validated zero margin at 21:9.
    local listLeftMargin = math.max(0.0, math.min(
        200.0,
        200.0 * (geometry.contentWidth - LEGACY_21X9_CONTENT_WIDTH) /
        (7680.0 - LEGACY_21X9_CONTENT_WIDTH)
    ))
    local widenedRoots = 0
    local resizedAreas = 0
    local resizedLists = 0

    for _, screenshotsArea in ipairs(
        collectByName(searchRoot, "screenshots_area", 24)
    ) do
        local areaSize = safe(function() return screenshotsArea:GetSize() end)
        local areaChanged = pcall(function()
            screenshotsArea:SetSize(
                screenshotsWidth,
                areaSize ~= nil and areaSize.Y or 1600.0
            )
            screenshotsArea:FlagForVisualInvalidation()
        end)
        if areaChanged then resizedAreas = resizedAreas + 1 end

        for _, list in ipairs(collectByName(screenshotsArea, "list", 4)) do
            local listSize = safe(function() return list:GetSize() end)
            local listChanged = pcall(function()
                list:SetSize(
                    screenshotsWidth,
                    listSize ~= nil and listSize.Y or 1600.0
                )
                list:SetMargin(listLeftMargin, 0.0, 0.0, 0.0)
                list:FlagForVisualInvalidation()
            end)
            if listChanged then resizedLists = resizedLists + 1 end
        end

        -- Path: Root/Root/global wrapper/scroll_listwrapper/screenshots_area.
        local targetRoot = screenshotsArea
        for _ = 1, 3 do
            targetRoot = targetRoot ~= nil and safe(function()
                return targetRoot:GetParentWidget()
            end) or nil
        end
        if targetRoot ~= nil and widgetName(targetRoot) == "Root" then
            local rootChanged = pcall(function()
                targetRoot:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
                targetRoot:FlagForVisualInvalidation()
            end)
            if rootChanged then widenedRoots = widenedRoots + 1 end
        end
    end

    local inputHints = 0
    for _, widget in ipairs(collectByName(searchRoot, "inputHints", 24)) do
        local margin = safe(function() return widget:GetMargin() end)
        local ok = pcall(function()
            widget:SetMargin(
                margin ~= nil and margin.left or 0.0,
                margin ~= nil and margin.top or 0.0,
                200.0,
                margin ~= nil and margin.bottom or 50.0
            )
            widget:FlagForVisualInvalidation()
        end)
        if ok then inputHints = inputHints + 1 end
    end

    if reason == "delayed" then
        dumpGalleryControllers(controller, searchRoot)
    end

    debugLog(string.format(
        "%s gallery %s: roots=%d areas=%d lists=%d width=%.2f inputHints=%d",
        LOG_PREFIX, reason, widenedRoots, resizedAreas, resizedLists,
        screenshotsWidth, inputHints
    ))
end

local function applyBreachProtocolLayout(controller, reason)
    cancelMainMenuRetries("breach protocol " .. tostring(reason))
    ensureMenuPillarsDisabled("breach protocol " .. tostring(reason))
    local geometry = getTargetGeometry()
    if geometry == nil or controller == nil then return end

    local searchRoot = safe(function() return controller:GetRootWidget() end)
    if searchRoot == nil then searchRoot = getMenuVirtualWindow() end
    if searchRoot == nil then return end

    -- Preserve the authored 3840-wide minigame itself and extend only its
    -- fullscreen decoration by half of the additional width on each side.
    local horizontalInset = math.max(
        0.0, (geometry.contentWidth - 3840.0) * 0.5
    )
    local tempBackgrounds = 0
    local headerHighlights = 0
    local backgroundLoops = 0
    local refreshedFluffColumns = 0

    for _, widget in ipairs(collectByName(searchRoot, "tempBG", 24)) do
        local ok = pcall(function()
            widget:SetMargin(
                -horizontalInset, 0.0, -horizontalInset, 0.0
            )
            widget:FlagForVisualInvalidation()
        end)
        if ok then tempBackgrounds = tempBackgrounds + 1 end
    end

    for _, widget in ipairs(
        collectByName(searchRoot, "header_ux_highlight", 24)
    ) do
        local ok = pcall(function()
            widget:SetAnchor(inkEAnchor.TopLeft)
            widget:SetAnchorPoint(Vector2.new({ X = 0.0, Y = 0.0 }))
            widget:SetMargin(-horizontalInset, 425.0, 0.0, 0.0)
            widget:SetSize(geometry.contentWidth, 170.0)
            widget:FlagForVisualInvalidation()
        end)
        if ok then headerHighlights = headerHighlights + 1 end
    end

    for _, widget in ipairs(collectByName(searchRoot, "bg_loop", 24)) do
        local ok = pcall(function()
            widget:SetMargin(
                -horizontalInset, 0.0, -horizontalInset, 0.0
            )
            widget:FlagForVisualInvalidation()
        end)
        if ok then backgroundLoops = backgroundLoops + 1 end
    end

    -- fluff_columns is not resized, but Ink keeps its pre-layout position
    -- cached after the sibling backgrounds are extended. Toggling a visible
    -- widget off and immediately back on forces the same harmless refresh as
    -- the confirmed Ink Inspector workaround, before the next rendered frame.
    for _, widget in ipairs(
        collectByName(searchRoot, "fluff_columns", 24)
    ) do
        local ok = pcall(function()
            local wasVisible = widget:IsVisible()
            if wasVisible then
                widget:SetVisible(false)
                widget:SetVisible(true)
            else
                widget:FlagForVisualInvalidation()
            end
        end)
        if ok then refreshedFluffColumns = refreshedFluffColumns + 1 end
    end

    debugLog(string.format(
        "%s breach protocol %s: inset=%.2f width=%.2f tempBG=%d header=%d bgLoop=%d fluffColumns=%d",
        LOG_PREFIX, reason, horizontalInset, geometry.contentWidth,
        tempBackgrounds, headerHighlights, backgroundLoops,
        refreshedFluffColumns
    ))
end

local function applyHubLayout(controller, reason)
    cancelMainMenuRetries("hub " .. tostring(reason))
    ensureMenuPillarsDisabled("hub " .. tostring(reason))
    local geometry = getTargetGeometry()
    if geometry == nil or controller == nil then return end

    local searchRoot = getMenuVirtualWindow()
    if searchRoot == nil then return end

    local rightLines = 0
    local widenedRoots = 0
    for _, widget in ipairs(collectByName(searchRoot, "Right_lines", 24)) do
        local ok = pcall(function()
            widget:SetMargin(geometry.contentWidth - 55.0, 0.0, 0.0, 0.0)
        end)
        if ok then rightLines = rightLines + 1 end

        -- Path: root/root2/root2/Right_lines. Two parents above the widget is
        -- the root/root2 layer that must be widened; no sibling order needed.
        local parent = safe(function() return widget:GetParentWidget() end)
        local targetRoot = parent ~= nil and safe(function()
            return parent:GetParentWidget()
        end) or nil
        if targetRoot ~= nil then
            local rootOk = pcall(function()
                targetRoot:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
            end)
            if rootOk then widenedRoots = widenedRoots + 1 end
        end
    end

    local fluffWidgets = 0
    for _, widget in ipairs(collectByName(searchRoot, "fluff", 24)) do
        local ok = pcall(function()
            widget:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
        end)
        if ok then fluffWidgets = fluffWidgets + 1 end
    end

    local rightFluffRoots = 0
    for _, widget in ipairs(collectByName(searchRoot, "Right_fluff_elements", 24)) do
        local targetRoot = safe(function() return widget:GetParentWidget() end)
        if targetRoot ~= nil then
            local ok = pcall(function()
                targetRoot:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
            end)
            if ok then rightFluffRoots = rightFluffRoots + 1 end
        end
    end

    local rightFluff = positionRightFluff(searchRoot, geometry, 24)

    debugLog(string.format(
        "%s hub %s: root2=%d rightLines=%d fluff=%d rightFluffRoots=%d rightFluff=%d",
        LOG_PREFIX, reason, widenedRoots, rightLines, fluffWidgets, rightFluffRoots,
        rightFluff
    ))
end

local function applyPauseMenuLayout(controller, reason)
    -- The Flatline screen instantiates the same background controller before
    -- DeathMenuGameController itself. Its scenario flag is therefore the
    -- earliest reliable discriminator. Never apply Pause Menu geometry there.
    if deathMenuActive then return end

    cancelMainMenuRetries("pause " .. tostring(reason))
    ensureMenuPillarsDisabled("pause " .. tostring(reason))
    local geometry = getTargetGeometry()
    if geometry == nil or controller == nil then return end

    local searchRoot = getMenuVirtualWindow()
    if searchRoot == nil then return end

    local rectangleRoots = 0
    for _, widget in ipairs(collectByName(searchRoot, "inkRectangleWidget14", 24)) do
        local parent = safe(function() return widget:GetParentWidget() end)
        if parent ~= nil then
            local ok = pcall(function()
                parent:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
            end)
            if ok then rectangleRoots = rectangleRoots + 1 end
        end
    end

    local bgFluffRoots = 0
    for _, widget in ipairs(collectByName(searchRoot, "bgFluff", 24)) do
        local parent = safe(function() return widget:GetParentWidget() end)
        if parent ~= nil then
            local ok = pcall(function()
                parent:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
            end)
            if ok then bgFluffRoots = bgFluffRoots + 1 end
        end
    end

    debugLog(string.format(
        "%s pause %s: rectangleRoots=%d bgFluffRoots=%d",
        LOG_PREFIX, reason, rectangleRoots, bgFluffRoots
    ))
end

local function applyMainMenuLayout(reason)
    mainMenuDiagnosticAttempt = mainMenuDiagnosticAttempt + 1

    local geometry = getTargetGeometry()
    if geometry == nil then
        diagnosticLog("apply " .. reason .. ": unsupported or unavailable display geometry")
        return false, false
    end

    local searchRoot = getMenuVirtualWindow()
    if searchRoot == nil then
        diagnosticLog("apply " .. reason .. ": inkMenuLayer virtual window unavailable")
        return false, false
    end

    -- Preem Menu replaces the vanilla bganim hierarchy with this specific
    -- runtime layout:
    --   VirtualWindow / Root (550x400) / Root (3840x2160) /
    --   backgroundContainer / <dynamic scene>
    -- Keep this compatibility path deliberately strict so a different main
    -- menu replacement is not treated as Preem merely because bganim is
    -- absent. Accept the already-expanded width on subsequent retry passes.
    local preemMenuDetected = false
    local preemRootsResized = 0
    local preemRootDescription = "none"
    local directChildCount = safe(function() return searchRoot:GetNumChildren() end) or 0
    for outerIndex = 0, directChildCount - 1 do
        local outerRoot = safe(function() return searchRoot:GetWidget(outerIndex) end)
        local outerSize = outerRoot ~= nil and safe(function() return outerRoot:GetSize() end) or nil
        local outerMatches = outerRoot ~= nil and widgetName(outerRoot) == "Root" and
            outerSize ~= nil and math.abs(outerSize.X - 550.0) <= 5.0 and
            math.abs(outerSize.Y - 400.0) <= 5.0

        if outerMatches then
            local innerChildCount = safe(function() return outerRoot:GetNumChildren() end) or 0
            for innerIndex = 0, innerChildCount - 1 do
                local innerRoot = safe(function() return outerRoot:GetWidget(innerIndex) end)
                local innerSize = innerRoot ~= nil and safe(function() return innerRoot:GetSize() end) or nil
                local innerWidthMatches = innerSize ~= nil and (
                    math.abs(innerSize.X - 3840.0) <= 5.0 or
                    math.abs(innerSize.X - geometry.contentWidth) <= 5.0
                )
                local innerMatches = innerRoot ~= nil and widgetName(innerRoot) == "Root" and
                    innerWidthMatches and innerSize ~= nil and
                    math.abs(innerSize.Y - REFERENCE_HEIGHT) <= 5.0

                if innerMatches then
                    local hasDirectBackgroundContainer = false
                    local contentCount = safe(function() return innerRoot:GetNumChildren() end) or 0
                    for contentIndex = 0, contentCount - 1 do
                        local content = safe(function() return innerRoot:GetWidget(contentIndex) end)
                        if content ~= nil and widgetName(content) == "backgroundContainer" then
                            hasDirectBackgroundContainer = true
                            break
                        end
                    end

                    if hasDirectBackgroundContainer then
                        preemMenuDetected = true
                        preemRootDescription = string.format(
                            "outer[%d]=%.1fx%.1f inner[%d]=%.1fx%.1f",
                            outerIndex, outerSize.X, outerSize.Y,
                            innerIndex, innerSize.X, innerSize.Y
                        )
                        local ok, errorMessage = pcall(function()
                            innerRoot:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
                        end)
                        if ok then
                            preemRootsResized = preemRootsResized + 1
                        else
                            diagnosticLog("Preem Menu root resize failed: " .. tostring(errorMessage))
                        end
                    end
                end
            end
        end
    end

    local backgroundRoots = 0
    local bganimWidgets = collectByName(searchRoot, "bganim", 12)
    for _, widget in ipairs(bganimWidgets) do
        local parent = safe(function() return widget:GetParentWidget() end)
        if parent ~= nil then
            local ok, errorMessage = pcall(function()
                parent:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
            end)
            if ok then
                backgroundRoots = backgroundRoots + 1
            else
                diagnosticLog("bganim parent resize failed: " .. tostring(errorMessage))
            end
        end
    end

    local backgroundScenes = 0
    local childDescriptions = {}
    local coverScale = geometry.contentWidth / 3840.0
    local verticalCrop = (REFERENCE_HEIGHT * coverScale - REFERENCE_HEIGHT) * 0.5
    local horizontalInset = (geometry.contentWidth - 3840.0) * 0.5
    local backgroundContainers = collectByName(searchRoot, "backgroundContainer", 12)
    for containerIndex, container in ipairs(backgroundContainers) do
        local childCount = safe(function() return container:GetNumChildren() end) or 0
        table.insert(childDescriptions, string.format(
            "container%d children=%d", containerIndex, childCount
        ))
        for index = 0, childCount - 1 do
            local child = safe(function() return container:GetWidget(index) end)
            if child ~= nil then
                local childName = widgetName(child)
                table.insert(childDescriptions, string.format(
                    "container%d[%d]=%s", containerIndex, index, childName
                ))
                local ok, errorMessage = pcall(function()
                    -- The game dynamically selects the scene placed inside
                    -- backgroundContainer. Scale that scene by position in
                    -- the hierarchy instead of depending on a resource name
                    -- such as v_apt_shot1.
                    child:SetScale(Vector2.new({
                        X = coverScale,
                        Y = coverScale
                    }))
                    child:SetTranslation(Vector2.new({
                        X = 0.0,
                        Y = -verticalCrop
                    }))
                    child:SetMargin(horizontalInset, 0.0, 0.0, 0.0)
                end)
                if ok then
                    backgroundScenes = backgroundScenes + 1
                else
                    diagnosticLog(string.format(
                        "scene transform failed for %s: %s",
                        childName, tostring(errorMessage)
                    ))
                end
            end
        end
    end

    debugLog(string.format(
        "%s mainMenu %s: backgroundRoots=%d backgroundScenes=%d",
        LOG_PREFIX, reason, backgroundRoots, backgroundScenes
    ))

    -- Vanilla/Cleaner use bganim. Preem Menu intentionally has no bganim and
    -- is authorized only by the exact hierarchy signature checked above.
    local vanillaBackgroundReady = backgroundRoots > 0
    local supportedLayoutReady = vanillaBackgroundReady or preemMenuDetected
    local sceneReady = backgroundScenes > 0
    local signature = string.format(
        "bganim=%d preem=%s preemRoots=%d preemPath={%s} containers=%d scenes=%d children={%s}",
        #bganimWidgets, tostring(preemMenuDetected), preemRootsResized,
        preemRootDescription, #backgroundContainers, backgroundScenes,
        table.concat(childDescriptions, ", ")
    )
    local signatureChanged = signature ~= mainMenuDiagnosticSignature
    if signatureChanged or mainMenuDiagnosticAttempt % 10 == 0 then
        diagnosticLog(string.format(
            "apply #%d (%s): %s scale=%.4f inset=%.2f crop=%.2f",
            mainMenuDiagnosticAttempt, reason, signature,
            coverScale, horizontalInset, verticalCrop
        ))
        mainMenuDiagnosticSignature = signature
    end

    if signatureChanged and sceneReady and not supportedLayoutReady then
        diagnosticLog(
            "BLOCKED: scene is ready but pillar removal was not scheduled; " ..
            "neither vanilla bganim nor the strict Preem Menu hierarchy was detected"
        )
    end

    -- The container may exist several seconds before its selected scene is
    -- attached. Use the actual child as the readiness signal for both the
    -- transform and pillar removal.
    if supportedLayoutReady and sceneReady and
       not mainMenuPillarPending and not mainMenuPillarsDisabled then
        mainMenuPillarPending = true
        mainMenuPillarTimer = 0.10
        diagnosticLog(string.format(
            "main-menu scene ready (%s); pillar removal scheduled in 0.10s",
            preemMenuDetected and "Preem Menu" or "vanilla-compatible layout"
        ))
    end
    return supportedLayoutReady, sceneReady
end

local function applySystemNotificationLayout()
    local geometry = getTargetGeometry()
    if geometry == nil then return end

    local layer = safe(function()
        return Game.GetInkSystem():GetLayer(CName.new("inkSystemNotificationsLayer"))
    end)
    local virtualWindow = layer ~= nil and safe(function()
        return layer:GetVirtualWindow()
    end) or nil
    if virtualWindow == nil then return end

    -- ExitGame has no script Game Controller. Its Context identifies the
    -- resource as system_notifications.inkwidget / ExitGame / Root/Canvas.
    -- Follow that fixed two-level path; do not recursively scan this layer
    -- every frame while no notification is visible.
    local root = safe(function() return virtualWindow:GetWidget(0) end)
    local canvas = root ~= nil and safe(function() return root:GetWidget(0) end) or nil
    local size = canvas ~= nil and safe(function() return canvas:GetSize() end) or nil
    if canvas ~= nil and widgetName(canvas) == "Canvas" and size ~= nil and
        size.X >= 3800.0 and size.X <= 3860.0 and
        size.Y >= 2100.0 and size.Y <= 2200.0 then
        pcall(function()
            canvas:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
        end)
    end
end

local function applyTimeSkipLayout(controller, reason)
    cancelMainMenuRetries("time skip " .. tostring(reason))
    ensureMenuPillarsDisabled("time skip " .. tostring(reason))
    local geometry = getTargetGeometry()
    if geometry == nil or controller == nil then return end

    -- Context: gameuiTimeskipGameController, Root/NotificationsContainer/
    -- UNINITIALIZED_WIDGET/Root. The controller root is the popup's 16:9
    -- canvas, so it can be widened directly without touching the shared
    -- inkGameNotificationsLayer.
    local root = safe(function() return controller:GetRootWidget() end)
    if root == nil then
        debugLog(LOG_PREFIX .. " time skip root unavailable during " .. reason)
        return
    end

    local ok, errorMessage = pcall(function()
        root:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
    end)
    if not ok then
        print(LOG_PREFIX .. " time skip layout failed: " .. tostring(errorMessage))
    end
end

local function applyGameNotificationLayouts()
    -- DeathMenuGameController shares a generic Root/wrapper notification shape
    -- with the Gallery viewer. Leave the Flatline screen completely vanilla;
    -- otherwise the Gallery compatibility path widens it by mistake.
    if deathMenuActive then return false end

    local geometry = getTargetGeometry()
    if geometry == nil then return false end

    local layer = safe(function()
        return Game.GetInkSystem():GetLayer(CName.new("inkGameNotificationsLayer"))
    end)
    local virtualWindow = layer ~= nil and safe(function() return layer:GetVirtualWindow() end) or nil
    if virtualWindow == nil then return false end

    local changed = false

    -- The first Root is expressed in the 1080-high viewport coordinate space,
    -- not the 2160-high widget coordinate space used by popup contents. Apart
    -- from being the normal layout, restoring it here also removes any stale
    -- value left by a live Ink Inspector or diagnostic edit.
    local layerRoot = safe(function() return virtualWindow:GetWidget(0) end)
    local layerRootSize = layerRoot ~= nil and safe(function()
        return layerRoot:GetSize()
    end) or nil
    if layerRoot ~= nil and layerRootSize ~= nil and
       (math.abs(layerRootSize.X - geometry.viewportWidth) > 0.5 or
        math.abs(layerRootSize.Y - VIEWPORT_HEIGHT) > 0.5) then
        local ok = pcall(function()
            layerRoot:SetSize(geometry.viewportWidth, VIEWPORT_HEIGHT)
            layerRoot:FlagForVisualInvalidation()
        end)
        if ok then changed = true end
    end

    -- Supported context paths:
    -- Reset Attributes:
    --   Root/NotificationsContainer/UNINITIALIZED_WIDGET/Root/notification
    -- Gallery photo viewer:
    --   Root/NotificationsContainer/UNINITIALIZED_WIDGET/Root/wrapper
    -- Journal database-entry detail:
    --   Root/NotificationsContainer/UNINITIALIZED_WIDGET/
    --   RootNotifications/entryView
    -- Walk that short fixed hierarchy directly. The popup controller exposed
    -- by CET does not own this outer 3840x2160 Root, so controller-based
    -- resizing cannot reach it.
    local layerRootChildren = layerRoot ~= nil and
        (safe(function() return layerRoot:GetNumChildren() end) or 0) or 0
    for containerIndex = 0, layerRootChildren - 1 do
        local notificationsContainer = safe(function()
            return layerRoot:GetWidget(containerIndex)
        end)
        local containerName = notificationsContainer ~= nil and
            widgetName(notificationsContainer) or ""

        -- Breach Protocol tutorial overlay:
        -- Root/TutorialOverlayContainer/Root. The child remains authored in
        -- the centered 3840-wide space, so move it by half the extra width.
        if containerName == "TutorialOverlayContainer" then
            local tutorialInset = math.max(
                0.0, (geometry.contentWidth - 3840.0) * 0.5
            )
            local tutorialChildCount = safe(function()
                return notificationsContainer:GetNumChildren()
            end) or 0
            for tutorialIndex = 0, tutorialChildCount - 1 do
                local tutorialRoot = safe(function()
                    return notificationsContainer:GetWidget(tutorialIndex)
                end)
                local ownsGlowList = false
                local tutorialRootChildren = tutorialRoot ~= nil and
                    (safe(function()
                        return tutorialRoot:GetNumChildren()
                    end) or 0) or 0
                for childIndex = 0, tutorialRootChildren - 1 do
                    local child = safe(function()
                        return tutorialRoot:GetWidget(childIndex)
                    end)
                    if child ~= nil and
                       widgetName(child) == "glowListContainer3" then
                        ownsGlowList = true
                        break
                    end
                end
                if tutorialRoot ~= nil and
                   widgetName(tutorialRoot) == "Root" and ownsGlowList then
                    local margin = safe(function()
                        return tutorialRoot:GetMargin()
                    end)
                    if margin == nil or
                       math.abs(margin.left - tutorialInset) > 0.5 or
                       math.abs(margin.top) > 0.5 or
                       math.abs(margin.right) > 0.5 or
                       math.abs(margin.bottom) > 0.5 then
                        local ok = pcall(function()
                            tutorialRoot:SetMargin(
                                tutorialInset, 0.0, 0.0, 0.0
                            )
                            tutorialRoot:FlagForVisualInvalidation()
                        end)
                        if ok then changed = true end
                    end

                    for childIndex = 0, tutorialRootChildren - 1 do
                        local child = safe(function()
                            return tutorialRoot:GetWidget(childIndex)
                        end)
                        if child ~= nil and widgetName(child) == "bg" then
                            local backgroundMargin = safe(function()
                                return child:GetMargin()
                            end)
                            local backgroundSize = safe(function()
                                return child:GetSize()
                            end)
                            if backgroundMargin == nil or backgroundSize == nil or
                               math.abs(
                                   backgroundSize.X - geometry.contentWidth
                               ) > 0.5 or
                               math.abs(
                                   backgroundMargin.left + tutorialInset
                               ) > 0.5 or
                               math.abs(backgroundMargin.top) > 0.5 or
                               math.abs(backgroundMargin.right) > 0.5 or
                               math.abs(backgroundMargin.bottom) > 0.5 then
                                local ok = pcall(function()
                                    child:SetSize(
                                        geometry.contentWidth,
                                        backgroundSize ~= nil and
                                            backgroundSize.Y or REFERENCE_HEIGHT
                                    )
                                    child:SetMargin(
                                        -tutorialInset, 0.0, 0.0, 0.0
                                    )
                                    child:FlagForVisualInvalidation()
                                end)
                                if ok then changed = true end
                            end
                        end
                    end
                end
            end
        end

        if notificationsContainer ~= nil and
           containerName == "NotificationsContainer" then
            local slotCount = safe(function()
                return notificationsContainer:GetNumChildren()
            end) or 0
            for slotIndex = 0, slotCount - 1 do
                local slot = safe(function()
                    return notificationsContainer:GetWidget(slotIndex)
                end)
                local popupCount = slot ~= nil and
                    (safe(function() return slot:GetNumChildren() end) or 0) or 0
                for popupIndex = 0, popupCount - 1 do
                    local popupRoot = safe(function()
                        return slot:GetWidget(popupIndex)
                    end)
                    local popupSize = popupRoot ~= nil and safe(function()
                        return popupRoot:GetSize()
                    end) or nil
                    local popupRootName = popupRoot ~= nil and
                        widgetName(popupRoot) or ""
                    if popupRoot ~= nil and
                       (popupRootName == "Root" or
                        popupRootName == "RootNotifications") and
                       popupSize ~= nil and popupSize.X >= 3800.0 and
                       popupSize.X <= 3860.0 and popupSize.Y >= 2100.0 and
                       popupSize.Y <= 2200.0 then
                        local childCount = safe(function()
                            return popupRoot:GetNumChildren()
                        end) or 0
                        for childIndex = 0, childCount - 1 do
                            local child = safe(function()
                                return popupRoot:GetWidget(childIndex)
                            end)
                            local childName = child ~= nil and widgetName(child) or ""
                            local isResetAttributes =
                                popupRootName == "Root" and
                                childName == "notification"
                            local isGalleryViewer =
                                popupRootName == "Root" and
                                childName == "wrapper"
                            local isJournalEntry =
                                popupRootName == "RootNotifications" and
                                childName == "entryView"
                            if isResetAttributes or isGalleryViewer or
                               isJournalEntry then
                                local ok = pcall(function()
                                    popupRoot:SetSize(
                                        geometry.contentWidth,
                                        REFERENCE_HEIGHT
                                    )
                                    popupRoot:FlagForVisualInvalidation()
                                end)
                                if ok then
                                    changed = true
                                    ensureMenuPillarsDisabled(
                                        isResetAttributes and
                                            "reset attributes notification tree" or
                                        isGalleryViewer and
                                            "gallery viewer notification tree" or
                                            "journal entry notification tree"
                                    )
                                end

                                -- The Gallery viewer also owns a separate
                                -- 3849-wide background. Widening its parent
                                -- does not affect this fixed-size child.
                                if isGalleryViewer then
                                    for _, background in ipairs(
                                        collectByName(popupRoot, "bg", 4)
                                    ) do
                                        local backgroundSize = safe(function()
                                            return background:GetSize()
                                        end)
                                        if backgroundSize ~= nil and
                                           backgroundSize.X >= 3800.0 and
                                           backgroundSize.X <= 3900.0 then
                                            local backgroundChanged = pcall(function()
                                                background:SetSize(
                                                    geometry.contentWidth,
                                                    backgroundSize.Y
                                                )
                                                background:FlagForVisualInvalidation()
                                            end)
                                            if backgroundChanged then changed = true end
                                        end
                                    end
                                end
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    -- StealthRunner's popup is spawned dynamically below the notifications
    -- layer. Restrict the search to this short-lived retry window; never scan
    -- the notification tree continuously while the game is running.
    local vignetteWidgets = collectByName(virtualWindow, "vignette", 12)
    for index, widget in ipairs(vignetteWidgets) do
        -- The popup contains a rectangle and an image with the same name.
        -- Only the first (the rectangle shown by Ink Inspector) is the
        -- 16:9 canvas that must be widened; leave the image texture intact.
        if index > 1 then break end
        -- The notifications layer only contains live popup widgets here;
        -- resize the discovered vignette without relying on a translated
        -- Name Path segment that may not be exposed by GetName().
        local ok = pcall(function()
            widget:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
            widget:FlagForVisualInvalidation()
        end)
        if ok then changed = true end
    end
    return changed
end

local function applySaveGameLayout(controller, reason)
    ensureMenuPillarsDisabled("save/load " .. tostring(reason))
    local geometry = getTargetGeometry()
    if geometry == nil or controller == nil then return end

    local searchRoot = getMenuVirtualWindow()
    if searchRoot == nil then return end

    local fluffs = 0
    for _, widget in ipairs(collectByName(searchRoot, "fluffs", 24)) do
        local ok = pcall(function()
            widget:SetMargin(
                extendMarginToEdge(-604.0, geometry), 16.0, 0.0, 0.0
            )
        end)
        if ok then fluffs = fluffs + 1 end
    end

    local revealedFluffs = 0
    for _, name in ipairs({ "fluff2", "fluff3" }) do
        for _, widget in ipairs(collectByName(searchRoot, name, 24)) do
            local ok = pcall(function()
                widget:SetVisible(true)
            end)
            if ok then revealedFluffs = revealedFluffs + 1 end
        end
    end


    local recenteredFluffs = 0
    for _, name in ipairs({ "fluff4", "fluff6", "fluff7" }) do
        for _, widget in ipairs(collectByName(searchRoot, name, 24)) do
            local margin = safe(function() return widget:GetMargin() end)
            if margin ~= nil then
                local ok = pcall(function()
                    widget:SetMargin(
                        margin.left + preserveCenteredMargin(600.0, geometry),
                        margin.top,
                        margin.right,
                        margin.bottom
                    )
                end)
                if ok then recenteredFluffs = recenteredFluffs + 1 end
            end
        end
    end

    local buttonHints = 0
    for _, widget in ipairs(collectByName(searchRoot, "button_hints", 24)) do
        local ok = pcall(function()
            widget:SetMargin(
                0.0, 0.0, extendMarginToEdge(-540.0, geometry), 120.0
            )
        end)
        if ok then buttonHints = buttonHints + 1 end
    end

    local lines = 0
    for _, widget in ipairs(collectByName(searchRoot, "line", 24)) do
        local ok = pcall(function()
            widget:SetMargin(
                extendMarginToEdge(-520.0, geometry),
                155.0,
                extendMarginToEdge(-1020.0, geometry),
                0.0
            )
        end)
        if ok then lines = lines + 1 end
    end

    debugLog(string.format(
        "%s saveGame %s: fluffs=%d revealedFluffs=%d recenteredFluffs=%d buttonHints=%d lines=%d",
        LOG_PREFIX, reason, fluffs, revealedFluffs, recenteredFluffs, buttonHints, lines
    ))
end

local function applySettingsLayout(controller, reason)
    ensureMenuPillarsDisabled("settings " .. tostring(reason))
    local geometry = getTargetGeometry()
    if geometry == nil or controller == nil then return end

    local searchRoot = getMenuVirtualWindow()
    if searchRoot == nil then return end

    local backgroundRoots = 0
    local backgrounds = 0
    local backgroundLayers = 0
    for _, widget in ipairs(collectByName(searchRoot, "BG", 24)) do
        local parent = safe(function() return widget:GetParentWidget() end)
        if parent ~= nil then
            local parentOk = pcall(function()
                parent:SetSize(geometry.contentWidth, REFERENCE_HEIGHT)
            end)
            if parentOk then backgroundRoots = backgroundRoots + 1 end
        end

        backgrounds = backgrounds + 1

        local childCount = safe(function() return widget:GetNumChildren() end) or 0
        for index = 0, childCount - 1 do
            local child = safe(function() return widget:GetWidget(index) end)
            local name = child ~= nil and widgetName(child) or ""
            if name == "background" then
                local ok = pcall(function()
                    -- Invisible vanilla sizing spacer: it intentionally stays
                    -- hidden but drives BG and all Fill children to 21:9.
                    child:SetWidth(geometry.contentWidth)
                    child:FlagForVisualInvalidation()
                end)
                if ok then backgroundLayers = backgroundLayers + 1 end
            elseif name == "bg1" or name == "bg2" or name == "bg3" then
                local scale = safe(function() return child:GetScale() end)
                if scale ~= nil then
                    pcall(function() child:SetScale(1.0, scale.Y) end)
                end
            end
        end

    end

    local rightSides = 0
    for _, widget in ipairs(collectByName(searchRoot, "rightSide", 24)) do
        local ok = pcall(function()
            widget:SetMargin(
                0.0, 346.0, preserveCenteredMargin(1545.0, geometry), 0.0
            )
        end)
        if ok then rightSides = rightSides + 1 end
    end

    local bottomFluffs = 0
    for _, widget in ipairs(collectByName(searchRoot, "inkHorizontalPanelWidget47", 24)) do
        local ok = pcall(function()
            widget:SetMargin(
                0.0, 0.0, extendMarginToEdge(-360.0, geometry), 70.0
            )
        end)
        if ok then bottomFluffs = bottomFluffs + 1 end
    end

    local modSettingsLists = 0
    local fullHorizontalInset = (geometry.contentWidth - 3840.0) * 0.5
    for _, widget in ipairs(collectByName(searchRoot, "mod_settings", 24)) do
        local ok = pcall(function()
            -- Keep the mod list attached to the left side of the centered
            -- configuration area instead of the physical ultrawide edge.
            widget:SetMargin(500.0 + fullHorizontalInset, 320.0, 0.0, 0.0)
        end)
        if ok then modSettingsLists = modSettingsLists + 1 end
    end

    local nativeModsLists = 0
    for _, widget in ipairs(collectByName(searchRoot, "extraButtons", 24)) do
        local ok = pcall(function()
            -- Native Settings UI mod list: use the same centered content
            -- boundary as Mod Settings while preserving its vanilla X base.
            widget:SetMargin(250.0 + fullHorizontalInset, 320.0, 0.0, 0.0)
        end)
        if ok then nativeModsLists = nativeModsLists + 1 end
    end

    local edgeFluffs = 0
    for _, widget in ipairs(collectByName(searchRoot, "edge_fluff", 24)) do
        local ok = pcall(function()
            -- Keep the vanilla animation coordinate space. Only its right
            -- decoration needs to move to the new physical edge.
            widget:SetSize(3840.0, REFERENCE_HEIGHT)

            local rightOffset = geometry.contentWidth - 3840.0
            for _, rightIcon in ipairs(collectByName(widget, "letter_icon_right", 8)) do
                rightIcon:SetMargin(0.0, 300.0, 20.0 - rightOffset, 0.0)
            end
        end)
        if ok then edgeFluffs = edgeFluffs + 1 end
    end

    debugLog(string.format(
        "%s settings %s: backgroundRoots=%d backgrounds=%d backgroundLayers=%d rightSides=%d bottomFluffs=%d modSettingsLists=%d nativeModsLists=%d edgeFluffs=%d",
        LOG_PREFIX, reason, backgroundRoots, backgrounds, backgroundLayers,
        rightSides, bottomFluffs, modSettingsLists, nativeModsLists, edgeFluffs
    ))
end

local function configureMapCamera(gameObject)
    local geometry = getTargetGeometry()
    if geometry == nil or gameObject == nil then return end

    local camera = gameObject:FindComponentByName("virtual_camera_comp")
    if camera == nil then
        debugLog(LOG_PREFIX .. " virtual_camera_comp unavailable")
        return
    end

    camera.resolutionWidth = geometry.cameraWidth
    camera.resolutionHeight = geometry.cameraHeight
    camera.aspectRatio = geometry.aspect

    debugLog(string.format(
        "%s camera=%dx%d aspect=%.6f",
        LOG_PREFIX, geometry.cameraWidth, geometry.cameraHeight, geometry.aspect
    ))
end

registerForEvent("onInit", function()
    if BACKPACK_LIFECYCLE_DIAGNOSTICS then
        local file = io.open(BACKPACK_LIFECYCLE_DIAGNOSTIC_FILE, "w")
        if file ~= nil then
            file:write(string.format(
                "[%s] [BackpackLifecycle] initialized; version=%s\n",
                os.date("%Y-%m-%d %H:%M:%S"), VERSION
            ))
            file:flush()
            file:close()
        end
    end
    initializeDiagnosticLog()
    local displayWidth, displayHeight = GetDisplayResolution()
    diagnosticLog(string.format(
        "%s v%s initialized at %dx%d",
        MOD_NAME, VERSION, displayWidth or -1, displayHeight or -1
    ))
    debugLog(string.format("%s %s v%s initialized", LOG_PREFIX, MOD_NAME, VERSION))

    -- On a real startup / pre-game reload, the asynchronous main-menu
    -- background still needs its finite discovery window. During an in-game
    -- CET reload, leave it disarmed; the dedicated main-menu lifecycle event
    -- will arm it if the game later returns there. Game.GetPlayer() is not a
    -- reliable discriminator because a residual player can exist pre-game.
    local preGame = isPreGame()
    if preGame == true then
        mainMenuRetryBudget = 1200
        mainMenuRetryTimer = 0.0
    else
        mainMenuRetryBudget = 0
        mainMenuRetryTimer = 0.0
    end
    diagnosticLog(string.format(
        "initial IsPreGame=%s mainMenuRetryBudget=%d",
        tostring(preGame), mainMenuRetryBudget
    ))

    -- Death Menu reuses PauseMenuBackgroundGameController. Detect the target
    -- scenario before that shared controller is initialized; waiting for
    -- DeathMenuGameController.OnInitialize is already one frame too late.
    local menuTransitionSources = {
        "MenuScenario_Idle",
        "MenuScenario_BaseMenu",
        "MenuScenario_PreGameSubMenu",
        "MenuScenario_SingleplayerMenu"
    }
    for _, scenarioClass in ipairs(menuTransitionSources) do
        local observedScenarioClass = scenarioClass
        pcall(function()
            ObserveBefore(observedScenarioClass, "OnLeaveScenario", function(firstArg, menuName)
                if type(menuName) ~= "userdata" then menuName = firstArg end
                if cnameEquals(menuName, "MenuScenario_DeathMenu") then
                    deathMenuActive = true
                    stealthRunnerRetryBudget = 0
                    stealthRunnerRetryTimer = 0.0
                elseif cnameEquals(menuName, "MenuScenario_Storage") then
                    stashMenuActive = true
                    stashLayoutFinalized = false
                    stashGeometryApplied = false
                    stashDataViewsRefreshed = false
                    stashPlayerInventoryPopulated = false
                    stashVendorInventoryPopulated = false
                    stashDataRefreshScheduled = false
                    -- The two library instances arrive asynchronously. These
                    -- finite, exact-path retries cover both fast and slow UI
                    -- creation without recursively scanning any widget tree.
                    for _, delay in ipairs({ 0.05, 0.15, 0.35, 0.75, 1.25, 2.0, 3.0 }) do
                        table.insert(pendingLayouts, {
                            controller = nil,
                            kind = "stash",
                            elapsed = 0.0,
                            delay = delay
                        })
                    end
                end
            end)
        end)
    end

    pcall(function()
        ObserveBefore("MenuScenario_DeathMenu", "OnLeaveScenario", function()
            deathMenuActive = false
        end)
    end)

    pcall(function()
        ObserveBefore("MenuScenario_Storage", "OnLeaveScenario", function()
            stashMenuActive = false
            stashLayoutFinalized = false
            stashGeometryApplied = false
            stashDataViewsRefreshed = false
            stashPlayerInventoryPopulated = false
            stashVendorInventoryPopulated = false
            stashDataRefreshScheduled = false
            for index = #pendingLayouts, 1, -1 do
                if pendingLayouts[index].kind == "stash" or
                   pendingLayouts[index].kind == "stashDataRefresh" then
                    table.remove(pendingLayouts, index)
                end
            end
        end)
    end)

    pcall(function()
        Observe("gameuiPreGameMenuGameController", "OnInitialize", function()
            diagnosticLog("event: gameuiPreGameMenuGameController.OnInitialize")
            mainMenuRetryBudget = 1200
            mainMenuRetryTimer = 0.0
            mainMenuSceneReadyPasses = 0
        end)
    end)

    pcall(function()
        Observe("SingleplayerMenuGameController", "OnInitialize", function()
            diagnosticLog("event: SingleplayerMenuGameController.OnInitialize")
            mainMenuRetryBudget = 1200
            mainMenuRetryTimer = 0.0
            mainMenuSceneReadyPasses = 0
        end)
    end)

    Observe("WorldMapMenuGameController", "OnInitialize", function(controller)
        applyWorldMapLayout(controller, "OnInitialize")
        table.insert(pendingLayouts, { controller = controller, kind = "map", elapsed = 0.0 })
    end)

    Observe("WorldMapMenuGameController", "OnEntityAttached", function(controller)
        applyWorldMapLayout(controller, "OnEntityAttached")
    end)

    Observe("gameuiWorldMapGameObject", "OnGameAttached", function(gameObject)
        local ok, errorMessage = pcall(function()
            configureMapCamera(gameObject)
        end)
        if not ok then
            print(LOG_PREFIX .. " camera configuration failed: " .. tostring(errorMessage))
        end
    end)

    Observe("gameuiInventoryGameController", "OnInitialize", function(controller)
        applyInventoryLayout(controller, "OnInitialize")
        table.insert(pendingLayouts, { controller = controller, kind = "inventory", elapsed = 0.0 })
    end)

    ObserveBefore("gameuiInGameMenuGameController", "OnInitialize", function(controller)
        if not stashMenuActive then return end
        applyStashLayout(controller, "BeforeOnInitialize")
    end)

    Observe("gameuiInGameMenuGameController", "OnInitialize", function(controller)
        if not stashMenuActive then return end
        applyStashLayout(controller, "OnInitialize")
    end)

    Observe("FullscreenVendorGameController", "OnInitialize", function(controller)
        if not stashMenuActive then return end
        applyStashLayout(controller, "FullscreenVendor.OnInitialize")
    end)

    pcall(function()
        Observe(
            "FullscreenVendorGameController",
            "OnPlayerSortingButtonClicked",
            function()
                positionStashSortingDropdown(
                    "playerPanel",
                    "OnPlayerSortingButtonClicked"
                )
            end
        )
    end)

    pcall(function()
        Observe(
            "FullscreenVendorGameController",
            "OnVendorSortingButtonClicked",
            function()
                positionStashSortingDropdown(
                    "vendorPanel",
                    "OnVendorSortingButtonClicked"
                )
            end
        )
    end)

    pcall(function()
        Observe("FullscreenVendorGameController", "PopulatePlayerInventory", function(controller)
            if not stashMenuActive then return end
            stashPlayerInventoryPopulated = true
            if stashVendorInventoryPopulated and not stashDataRefreshScheduled then
                stashDataRefreshScheduled = true
                table.insert(pendingLayouts, {
                    controller = controller,
                    kind = "stashDataRefresh",
                    elapsed = 0.0,
                    delay = 0.20
                })
            end
        end)
    end)

    pcall(function()
        Observe("FullscreenVendorGameController", "PopulateVendorInventory", function(controller)
            if not stashMenuActive then return end
            stashVendorInventoryPopulated = true
            if stashPlayerInventoryPopulated and not stashDataRefreshScheduled then
                stashDataRefreshScheduled = true
                table.insert(pendingLayouts, {
                    controller = controller,
                    kind = "stashDataRefresh",
                    elapsed = 0.0,
                    delay = 0.20
                })
            end
        end)
    end)

    Observe("CyberwareMainGameController", "OnInitialize", function(controller)
        applyCyberwareLayout(controller, "OnInitialize")
        table.insert(pendingLayouts, { controller = controller, kind = "cyberware", elapsed = 0.0 })
    end)

    ObserveBefore("MenuScenario_HubMenu", "OnOpenMenu", function(_, menuName)
        activeHubMenu = cnameValue(menuName)
    end)

    Observe("MenuScenario_HubMenu", "OnOpenMenu", function(scenario, menuName)
        if cnameEquals(menuName, "cyberware_equip") then
            applyCyberwareLayout(scenario, "OnOpenMenu")
            table.insert(pendingLayouts, { controller = scenario, kind = "cyberware", elapsed = 0.0 })
        elseif cnameEquals(menuName, "backpack") then
            backpackLifecycleLog(
                "MenuScenario_HubMenu.OnOpenMenu observed; no layout mutation"
            )
        end
    end)

    ObserveBefore("MenuScenario_RadialHubMenu", "OnOpenMenu", function(_, menuName)
        activeHubMenu = cnameValue(menuName)
    end)

    Observe("MenuScenario_RadialHubMenu", "OnOpenMenu", function(scenario, menuName)
        if cnameEquals(menuName, "cyberware_equip") then
            applyCyberwareLayout(scenario, "OnOpenMenu")
            table.insert(pendingLayouts, { controller = scenario, kind = "cyberware", elapsed = 0.0 })
        elseif cnameEquals(menuName, "backpack") then
            backpackLifecycleLog(
                "MenuScenario_RadialHubMenu.OnOpenMenu observed; no layout mutation"
            )
        end
    end)

    Observe("ButtonHints", "OnInitialize", function(controller)
        local expectedName = menuHintWidgetNames[activeHubMenu]
        if expectedName == nil then return end

        local widget = safe(function() return controller:GetRootWidget() end)
        for _ = 1, 4 do
            if widget == nil then return end
            if widgetName(widget) == expectedName then
                local geometry = getTargetGeometry()
                if geometry == nil then return end
                if activeHubMenu == "backpack" then
                    widget:SetMargin(0.0, 0.0, 120.0, 50.0)
                elseif activeHubMenu == "shards" then
                    widget:SetMargin(0.0, 0.0, 200.0, 50.0)
                else
                    widget:SetMargin(
                        0.0, 0.0, extendMarginToEdge(-540.0, geometry), 50.0
                    )
                end
                debugLog(LOG_PREFIX .. " " .. activeHubMenu .. " " .. expectedName .. " initialized")
                return
            end
            widget = safe(function() return widget:GetParentWidget() end)
        end
    end)

    ObserveBefore("BackpackMainGameController", "OnInitialize", function(controller)
        backpackLifecycleLog(
            "BackpackMainGameController.BeforeOnInitialize observed"
        )
        applyBackpackLayout(controller, "BeforeOnInitialize")
    end)

    Observe("BackpackMainGameController", "OnInitialize", function(controller)
        backpackLifecycleLog(
            "BackpackMainGameController.OnInitialize completed; search positioning queued"
        )
        table.insert(pendingLayouts, {
            controller = controller,
            kind = "backpackSearch",
            elapsed = 0.0,
            delay = 0.0
        })
    end)

    local backpackUninitializeRegistered = pcall(function()
        Observe("BackpackMainGameController", "OnUninitialize", function(controller)
            backpackLifecycleLog(
                "BackpackMainGameController.OnUninitialize observed; guard released"
            )
            backpackLayoutAppliedControllers[controller] = nil
        end)
    end)
    if not backpackUninitializeRegistered then
        backpackLifecycleLog(
            "BackpackMainGameController.OnUninitialize observer unavailable"
        )
    end

    -- Optional Revised Backpack compatibility. Observe registration is wrapped
    -- because the class does not exist at all when the mod is not installed.
    pcall(function()
        Observe("RevisedBackpack.RevisedBackpackController", "OnInitialize", function(controller)
            debugLog(LOG_PREFIX .. " Revised Backpack controller observed")
            applyRevisedBackpackLayout(controller, "OnInitialize")
            table.insert(pendingLayouts, {
                controller = controller,
                kind = "revisedBackpack",
                elapsed = 0.0
            })
        end)
    end)

    pcall(function()
        Observe(
            "RevisedBackpack.RevisedBackpackItemController",
            "OnInitialize",
            function(controller)
                resizeRevisedBackpackItemRow(controller)
            end
        )
    end)

    Observe("CraftingMainGameController", "OnInitialize", function(controller)
        applyAuxiliaryMenuLayout(controller, "OnInitialize", "crafting", "buttonHintContainer")
        table.insert(pendingLayouts, { controller = controller, kind = "auxiliary", label = "crafting", hintName = "buttonHintContainer", elapsed = 0.0 })
    end)

    Observe("StatsMainGameController", "OnInitialize", function(controller)
        applyAuxiliaryMenuLayout(controller, "OnInitialize", "stats", "button_hints")
        table.insert(pendingLayouts, { controller = controller, kind = "auxiliary", label = "stats", hintName = "button_hints", elapsed = 0.0 })
    end)

    ObserveBefore("GalleryMenuGameController", "OnInitialize", function(controller)
        if not isMainGalleryController(controller) then return end

        local screenshotsPerPage = getGalleryScreenshotsPerPage()
        local ok, errorMessage = pcall(function()
            controller.screenshotsPerPage = screenshotsPerPage
        end)
        if not ok then
            print(LOG_PREFIX .. " gallery page-size update failed: " ..
                tostring(errorMessage))
        end
    end)

    Observe("GalleryMenuGameController", "OnInitialize", function(controller)
        if not isMainGalleryController(controller) then return end

        applyGalleryLayout(controller, "OnInitialize")
        table.insert(pendingLayouts, {
            controller = controller,
            kind = "gallery",
            elapsed = 0.0
        })
    end)

    Observe("ShardsMenuGameController", "OnInitialize", function(controller)
        applyAuxiliaryMenuLayout(controller, "OnInitialize", "shards", "button_hints")
        table.insert(pendingLayouts, { controller = controller, kind = "auxiliary", label = "shards", hintName = "button_hints", elapsed = 0.0 })
    end)

    Observe("HackingMinigameGameController", "OnInitialize", function(controller)
        applyBreachProtocolLayout(controller, "OnInitialize")
        table.insert(pendingLayouts, {
            controller = controller,
            kind = "breachProtocol",
            elapsed = 0.0
        })
    end)

    Observe("gameuiTimeskipGameController", "OnInitialize", function(controller)
        applyTimeSkipLayout(controller, "OnInitialize")
        table.insert(pendingLayouts, {
            controller = controller,
            kind = "timeskip",
            elapsed = 0.0,
            delay = 0.10
        })
    end)

    Observe("PerksMainGameController", "OnInitialize", function(controller)
        applyCharacterLayout(controller, "OnInitialize")
        table.insert(pendingLayouts, { controller = controller, kind = "character", elapsed = 0.0 })
    end)

    Observe("NewPerksCategoriesGameController", "OnInitialize", function(controller)
        applyCharacterLayout(controller, "OnInitialize")
        table.insert(pendingLayouts, { controller = controller, kind = "character", elapsed = 0.0 })
    end)

    Observe("questLogGameController", "OnInitialize", function(controller)
        applyJournalLayout(controller, "OnInitialize")
        table.insert(pendingLayouts, { controller = controller, kind = "journal", elapsed = 0.0 })
    end)

    Observe("CodexGameController", "OnInitialize", function(controller)
        applyDatabaseLayout(controller, "OnInitialize")
        table.insert(pendingLayouts, {
            controller = controller,
            kind = "database",
            elapsed = 0.0
        })
    end)

    Observe("MenuHubLogicController", "OnInitialize", function(controller)
        applyHubLayout(controller, "OnInitialize")
        table.insert(pendingLayouts, { controller = controller, kind = "hub", elapsed = 0.0, delay = 0.0 })
    end)

    Observe("RadialMenuHubLogicController", "OnInitialize", function(controller)
        applyHubLayout(controller, "OnInitialize")
        table.insert(pendingLayouts, { controller = controller, kind = "hub", elapsed = 0.0, delay = 0.0 })
    end)

    ObserveBefore("PauseMenuBackgroundGameController", "OnInitialize", function()
        activeHubMenu = ""
    end)

    Observe("PauseMenuBackgroundGameController", "OnInitialize", function(controller)
        applyPauseMenuLayout(controller, "Background.OnInitialize")
        table.insert(pendingLayouts, { controller = controller, kind = "pause", elapsed = 0.0, delay = 0.0 })
    end)

    ObserveBefore("PauseMenuGameController", "OnInitialize", function()
        activeHubMenu = ""
    end)

    Observe("PauseMenuGameController", "OnInitialize", function(controller)
        applyPauseMenuLayout(controller, "OnInitialize")
        table.insert(pendingLayouts, { controller = controller, kind = "pause", elapsed = 0.0, delay = 0.0 })
    end)

    ObserveBefore("DeathMenuGameController", "OnInitialize", function()
        deathMenuActive = true
        -- Do not let a notification retry armed immediately before death
        -- inspect and modify the Flatline widget tree.
        stealthRunnerRetryBudget = 0
        stealthRunnerRetryTimer = 0.0
    end)

    Observe("DeathMenuGameController", "OnUninitialize", function()
        deathMenuActive = false
        stealthRunnerScanTimer = 0.0
    end)

    Observe("SingleplayerMenuGameController", "OnSavesForLoadReady", function(controller)
        diagnosticLog("event: SingleplayerMenuGameController.OnSavesForLoadReady")
        mainMenuPillarPending = false
        mainMenuPillarsDisabled = false
        mainMenuPillarTimer = 0.0
        mainMenuDiagnosticAttempt = 0
        mainMenuDiagnosticSignature = ""
        mainMenuSceneReadyPasses = 0
        applyMainMenuLayout("OnSavesForLoadReady")
        mainMenuRetryBudget = 1200
        mainMenuRetryTimer = 0.0
    end)

    -- StealthRunner's status popup is created after the notifications layer
    -- is initialized. These callbacks arm a short retry window so the newly
    -- spawned vignette can be found without a permanent recursive scan.
    pcall(function()
        Observe("gameuiPopupsManager", "OnUpdateVisibility", function()
            stealthRunnerRetryBudget = 20
            stealthRunnerRetryTimer = 0.0
        end)
        Observe("gameuiPopupsManager", "OnUpdateData", function()
            stealthRunnerRetryBudget = 20
            stealthRunnerRetryTimer = 0.0
        end)
        -- Generic notification controllers are also used for popup resources
        -- that do not update PopupsManager's tutorial blackboard.
        Observe("GenericNotificationController", "OnInitialize", function()
            stealthRunnerRetryBudget = 20
            stealthRunnerRetryTimer = 0.0
        end)
    end)

    Observe("SaveGameMenuGameController", "OnInitialize", function(controller)
        applySaveGameLayout(controller, "OnInitialize")
    end)

    Observe("LoadGameMenuGameController", "OnInitialize", function(controller)
        applySaveGameLayout(controller, "LoadGame.OnInitialize")
    end)

    Observe("SettingsMainGameController", "OnInitialize", function(controller)
        applySettingsLayout(controller, "OnInitialize")
        table.insert(pendingLayouts, { controller = controller, kind = "settingsFinalize", elapsed = 0.0, delay = 0.75 })
    end)

    -- Optional compatibility: Mod Settings is not required by this mod.
    pcall(function()
        Observe("ModStngsMainGameController", "OnInitialize", function(controller)
            applySettingsLayout(controller, "ModSettings.OnInitialize")
            table.insert(pendingLayouts, { controller = controller, kind = "settingsFinalize", elapsed = 0.0, delay = 0.75 })
        end)
    end)
end)

registerForEvent("onUpdate", function(deltaTime)
    applySystemNotificationLayout()

    -- A startup mod may bypass the pre-game menu and load the last save
    -- directly. Cancel the discovery window when the engine leaves its true
    -- pre-game state so it cannot spill into the first in-game menu.
    if mainMenuRetryBudget > 0 and isPreGame() == false then
        cancelMainMenuRetries("engine left pre-game")
    end

    if BACKPACK_TREE_DIAGNOSTICS and
        not backpackTreeDumped and not backpackTreeDumpFailed then
        backpackTreeScanTimer = backpackTreeScanTimer + deltaTime
        if backpackTreeScanTimer >= 0.25 then
            backpackTreeScanTimer = 0.0
            local searchRoot = getMenuVirtualWindow()
            if searchRoot ~= nil then
                for _, inventoryWrapper in ipairs(
                    collectByName(searchRoot, "inventory_wrapper", 24)
                ) do
                    local parent = safe(function()
                        return inventoryWrapper:GetParentWidget()
                    end)
                    if parent ~= nil and widgetName(parent) == "wrapper" then
                        dumpBackpackWidgetTree(inventoryWrapper)
                        break
                    end
                end
            end
        end
    end

    if mainMenuPillarPending then
        mainMenuPillarTimer = mainMenuPillarTimer - deltaTime
        if mainMenuPillarTimer <= 0.0 then
            diagnosticLog("pillar timer elapsed; requesting disabled pillars")
            local ok, errorMessage = pcall(function()
                local coordinator = GetMod("BlackPillarsCoordinator")
                if coordinator ~= nil and coordinator.SetPillarsDisabled ~= nil then
                    diagnosticLog("calling BlackPillarsCoordinator.SetPillarsDisabled(true)")
                    coordinator.SetPillarsDisabled(true)
                elseif UWMenuSetPillarsDisabled ~= nil then
                    diagnosticLog("calling legacy UWMenuSetPillarsDisabled(true)")
                    UWMenuSetPillarsDisabled(true)
                else
                    diagnosticLog("coordinator unavailable; calling UWMapSetBlackBarsSuppressed(true)")
                    UWMapSetBlackBarsSuppressed(true)
                end
            end)
            mainMenuPillarPending = false
            mainMenuPillarsDisabled = ok
            diagnosticLog(ok and "pillar disable request completed" or
                ("pillar disable request failed: " .. tostring(errorMessage)))
        end
    end

    -- StealthRunner creates this notification without reliably notifying the
    -- PopupsManager blackboard. A throttled scan of this small layer is cheap
    -- and avoids a recursive walk every frame.
    stealthRunnerScanTimer = stealthRunnerScanTimer - deltaTime
    if stealthRunnerScanTimer <= 0.0 then
        applyGameNotificationLayouts()
        stealthRunnerScanTimer = 0.25
    end
    if stealthRunnerRetryBudget > 0 then
        stealthRunnerRetryTimer = stealthRunnerRetryTimer - deltaTime
        if stealthRunnerRetryTimer <= 0.0 then
            local found = applyGameNotificationLayouts()
            stealthRunnerRetryBudget = stealthRunnerRetryBudget - 1
            stealthRunnerRetryTimer = 0.10
            if found then
                stealthRunnerRetryBudget = 0
            end
        end
    end
    if mainMenuRetryBudget > 0 then
        mainMenuRetryTimer = mainMenuRetryTimer - deltaTime
        if mainMenuRetryTimer <= 0.0 then
            local backgroundReady, sceneReady = applyMainMenuLayout("retry")
            if sceneReady then
                mainMenuSceneReadyPasses = mainMenuSceneReadyPasses + 1
                if mainMenuSceneReadyPasses >= 15 then
                    diagnosticLog("scene transform stable for 15 passes; retries stopped")
                    mainMenuRetryBudget = 0
                else
                    mainMenuRetryBudget = mainMenuRetryBudget - 1
                    mainMenuRetryTimer = 0.10
                end
            else
                mainMenuSceneReadyPasses = 0
                -- The selected scene is inserted asynchronously into
                -- backgroundContainer. Once bganim exists, allow it a short
                -- grace period to appear, then stop scanning.
                if backgroundReady and mainMenuRetryBudget > 300 then
                    diagnosticLog("bganim ready; limiting scene search to 30 seconds")
                    mainMenuRetryBudget = 300
                end
                mainMenuRetryBudget = mainMenuRetryBudget - 1
                mainMenuRetryTimer = backgroundReady and 0.10 or 0.05
                if mainMenuRetryBudget == 0 then
                    diagnosticLog("scene search budget exhausted without a stable child")
                end
            end
        end
    end

    for index = #pendingLayouts, 1, -1 do
        local item = pendingLayouts[index]
        item.elapsed = item.elapsed + deltaTime
        if item.elapsed >= (item.delay or 0.75) then
            local ok, errorMessage = pcall(function()
                if item.kind == "inventory" then
                    applyInventoryLayout(item.controller, "delayed")
                elseif item.kind == "stash" then
                    applyStashLayout(item.controller, "delayed")
                elseif item.kind == "stashDataRefresh" then
                    stashDataViewsRefreshed = false
                    refreshStashDataViews(item.controller)
                elseif item.kind == "cyberware" then
                    applyCyberwareLayout(item.controller, "delayed")
                elseif item.kind == "character" then
                    applyCharacterLayout(item.controller, "delayed")
                elseif item.kind == "journal" then
                    applyJournalLayout(item.controller, "delayed")
                elseif item.kind == "database" then
                    applyDatabaseLayout(item.controller, "delayed")
                elseif item.kind == "gallery" then
                    applyGalleryLayout(item.controller, "delayed")
                elseif item.kind == "breachProtocol" then
                    applyBreachProtocolLayout(item.controller, "delayed")
                elseif item.kind == "backpackSearch" then
                    positionBackpackSearch(item.controller, "post-initialize")
                elseif item.kind == "revisedBackpack" then
                    applyRevisedBackpackLayout(item.controller, "delayed")
                elseif item.kind == "auxiliary" then
                    applyAuxiliaryMenuLayout(item.controller, "delayed", item.label, item.hintName)
                elseif item.kind == "hub" then
                    applyHubLayout(item.controller, "delayed")
                elseif item.kind == "pause" then
                    applyPauseMenuLayout(item.controller, "delayed")
                elseif item.kind == "settingsFinalize" then
                    applySettingsLayout(item.controller, "finalize")
                elseif item.kind == "timeskip" then
                    applyTimeSkipLayout(item.controller, "delayed")
                else
                    applyWorldMapLayout(item.controller, "delayed")
                end
            end)
            if not ok then
                print(LOG_PREFIX .. " delayed layout failed: " .. tostring(errorMessage))
            end
            table.remove(pendingLayouts, index)
        end
    end
end)

registerForEvent("onShutdown", function()
    pendingLayouts = {}
    backpackLayoutAppliedControllers = {}
    backpackTreeDumped = false
    backpackTreeScanTimer = 0.0
    backpackTreeDumpFailed = false
    craftingGridRebuiltControllers = {}
    mainMenuRetryBudget = 0
    mainMenuRetryTimer = 0.0
    mainMenuPillarTimer = 0.0
    mainMenuPillarPending = false
    mainMenuPillarsDisabled = false
    mainMenuDiagnosticAttempt = 0
    mainMenuDiagnosticSignature = ""
    mainMenuSceneReadyPasses = 0
    stealthRunnerRetryBudget = 0
    stealthRunnerRetryTimer = 0.0
    stealthRunnerScanTimer = 0.0
    deathMenuActive = false
    stashMenuActive = false
    stashLayoutFinalized = false
    stashGeometryApplied = false
    stashDataViewsRefreshed = false
    stashPlayerInventoryPopulated = false
    stashVendorInventoryPopulated = false
    stashDataRefreshScheduled = false
    stashTreeDumped = false
    stashControllerDumped = false
end)
