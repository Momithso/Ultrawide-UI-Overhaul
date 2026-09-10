-- Ultrawide UI Overhaul v2.2.2
-- Black Pillars Coordinator
--
-- The native plugin owns the compositor hook. This small, independent CET
-- module only tells it when fullscreen pillars are desirable:
--   * enabled during startup and loading screens;
--   * disabled in the main menu and in the playable world.
--
-- It intentionally does not touch the main UltrawideUIOverhaul layout script.

local pillarsDisabled = nil
local loadingActive = false
local publicApi = {}


---------------------------------------------------------------------------
-- Logging
---------------------------------------------------------------------------

local function logError(message)
    pcall(function()
        spdlog.error(
            "[BlackPillarsCoordinator] "
            .. tostring(message)
        )
    end)
end


---------------------------------------------------------------------------
-- Pillar state
---------------------------------------------------------------------------

local function setPillarsDisabled(disabled, force)
    if not force and pillarsDisabled == disabled then
        return
    end

    local ok, err = pcall(function()
        UWMapSetBlackBarsSuppressed(disabled)
    end)

    if ok then
        pillarsDisabled = disabled
    else
        logError(
            "UWMapSetBlackBarsSuppressed failed: "
            .. tostring(err)
        )
    end
end


-- Shared entry point used by the independent layout module.
--
-- When that module suppresses the pillars again, we are no longer in a
-- loading presentation. This is particularly important when returning to
-- the main menu, where QuestTracker.OnInitialize does not run.
UWMenuSetPillarsDisabled = function(disabled)
    if disabled then
        loadingActive = false
    end

    setPillarsDisabled(disabled, false)
end

publicApi.SetPillarsDisabled = function(disabled)
    UWMenuSetPillarsDisabled(disabled)
end


---------------------------------------------------------------------------
-- Loading lifecycle
---------------------------------------------------------------------------

local function beginLoading()
    -- LoadingScreenProgressBarController.SetProgress fires very frequently,
    -- so ignore subsequent calls once the loading transition is active.
    if loadingActive then
        return
    end

    loadingActive = true

    -- Force synchronization because the independent layout module may have
    -- changed the native compositor state while this local cache was stale.
    setPillarsDisabled(false, true)
end


local function endLoading()
    if not loadingActive then
        return
    end

    loadingActive = false

    -- The playable world is attached: suppress the stock pillars again.
    setPillarsDisabled(true, true)
end


---------------------------------------------------------------------------
-- Initialization
---------------------------------------------------------------------------

registerForEvent("onInit", function()

    -----------------------------------------------------------------------
    -- Startup
    -----------------------------------------------------------------------

    -- Do not overwrite the native compositor state here. The DLL starts with
    -- stock pillars enabled on a real process launch. During CET's
    -- "Reload All Mods", however, the DLL remains loaded and already holds
    -- the correct state for the current screen. Preserving it avoids both an
    -- early main-menu suppression and pillars reappearing in an attached
    -- playable session whose QuestTracker.OnInitialize will not be replayed.


    -----------------------------------------------------------------------
    -- Loading-screen fallback
    -----------------------------------------------------------------------

    -- Confirms that a loading screen is active.
    --
    -- This may fire too late to be the primary trigger for Continue or
    -- Load Game, so those paths are intercepted separately below.
    Observe(
        "LoadingScreenProgressBarController",
        "SetProgress",
        function()
            beginLoading()
        end
    )


    -----------------------------------------------------------------------
    -- MAIN MENU -> CONTINUE
    -----------------------------------------------------------------------

    -- PauseMenuAction.QuickLoad == 5.
    --
    -- This fires before LoadModdedSave / LoadLastCheckpoint, restoring the
    -- pillars before the loading presentation begins.
    local continueRegistered, continueError = pcall(function()

        ObserveBefore(
            "gameuiMenuItemListGameController",
            "OnMenuItemActivated",
            function(_, _, target)

                if target == nil then
                    return
                end

                local data = nil

                local dataOk = pcall(function()
                    data = target:GetData()
                end)

                if not dataOk or data == nil then
                    return
                end

                local action = -1

                pcall(function()
                    action =
                        tonumber(EnumInt(data.action))
                        or -1
                end)

                if action == 5 then
                    beginLoading()
                end
            end
        )
    end)


    if not continueRegistered then
        logError(
            "Failed to register Continue hook: "
            .. tostring(continueError)
        )
    end


    -----------------------------------------------------------------------
    -- MAIN MENU -> LOAD GAME -> SELECT SAVE
    -----------------------------------------------------------------------

    -- Detect the save-slot activation before LoadGame() starts creating the
    -- loading transition.
    local loadSlotRegistered, loadSlotError = pcall(function()

        ObserveBefore(
            "LoadGameMenuGameController",
            "OnRelease",
            function(_, event)

                if event == nil then
                    return
                end


                -----------------------------------------------------------
                -- Select / click activation
                -----------------------------------------------------------

                local isClick = false

                pcall(function()
                    isClick =
                        event:IsAction(
                            CName.new("click")
                        )
                end)

                if not isClick then
                    return
                end


                -----------------------------------------------------------
                -- Valid save slot
                -----------------------------------------------------------

                local validSlot = false

                pcall(function()

                    local widget =
                        event:GetCurrentTarget()

                    if widget == nil then
                        return
                    end

                    local controller =
                        widget:GetController()

                    if controller ~= nil
                        and controller:ValidSlot()
                    then
                        validSlot = true
                    end
                end)


                if validSlot then
                    beginLoading()
                end
            end
        )
    end)


    if not loadSlotRegistered then
        logError(
            "Failed to register Load Game slot hook: "
            .. tostring(loadSlotError)
        )
    end


    -----------------------------------------------------------------------
    -- LOAD GAME internal fallback
    -----------------------------------------------------------------------

    pcall(function()

        ObserveBefore(
            "LoadGameMenuGameController",
            "LoadGame;LoadListItem",
            function()
                beginLoading()
            end
        )
    end)


    -----------------------------------------------------------------------
    -- Native loading fallbacks
    -----------------------------------------------------------------------

    -- Vanilla latest-save Continue path.
    pcall(function()

        ObserveBefore(
            "inkISystemRequestsHandler",
            "LoadLastCheckpoint",
            function()
                beginLoading()
            end
        )
    end)


    -- Explicit vanilla save load.
    pcall(function()

        ObserveBefore(
            "inkISystemRequestsHandler",
            "LoadSavedGame",
            function()
                beginLoading()
            end
        )
    end)


    -- Modded latest-save Continue path.
    pcall(function()

        ObserveBefore(
            "gameuiSaveHandlingController",
            "LoadModdedSave",
            function()
                beginLoading()
            end
        )
    end)


    -- Loading-screen preparation.
    pcall(function()

        ObserveBefore(
            "gameuiSaveHandlingController",
            "PreSpawnInitialLoadingScreen",
            function()
                beginLoading()
            end
        )
    end)


    -- General save-loading path.
    pcall(function()

        ObserveBefore(
            "gameuiSaveHandlingController",
            "LoadSaveInGame",
            function()
                beginLoading()
            end
        )
    end)


    -----------------------------------------------------------------------
    -- Quick load from gameplay
    -----------------------------------------------------------------------

    pcall(function()

        ObserveBefore(
            "gameuiInGameMenuGameController",
            "OnQuickLoadSavesReady",
            function()
                beginLoading()
            end
        )
    end)


    -----------------------------------------------------------------------
    -- PLAYABLE WORLD ATTACHED
    -----------------------------------------------------------------------

    -- Session-loaded marker also used by psiberX's GameUI.
    --
    -- QuestTrackerGameController.OnInitialize means the playable session /
    -- HUD has attached. The loading presentation is over.
    Observe(
        "QuestTrackerGameController",
        "OnInitialize",
        function()
            endLoading()
        end
    )


    -----------------------------------------------------------------------
    -- PLAYABLE WORLD -> LOADING
    -----------------------------------------------------------------------

    -- Fallback for transitions that do not originate from one of the
    -- explicit save/loading paths above.
    Observe(
        "QuestTrackerGameController",
        "OnUninitialize",
        function()

            if Game.GetPlayer() == nil then
                beginLoading()
            end
        end
    )
end)


---------------------------------------------------------------------------
-- Shutdown
---------------------------------------------------------------------------

registerForEvent("onShutdown", function()

    loadingActive = false
    pillarsDisabled = nil

    -- Keep the native state intact across CET hot reloads. On a real game
    -- shutdown the DLL is unloaded immediately afterwards, so no compositor
    -- state needs to be restored from Lua.

    UWMenuSetPillarsDisabled = nil
end)

return publicApi
