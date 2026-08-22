-- MDMDialogLoader.lua
-- Centralized lazy-loading registry for MDM modal dialogs.
-- Pattern matches NPCFavor's confirmed DialogLoader.
--
-- Usage:
--   MDMDialogLoader.init(modDir)
--   MDMDialogLoader.register("MDMContractDialog", MDMContractDialog, "xml/gui/MDMContractDialog.xml")
--   MDMDialogLoader.show("MDMContractDialog", "setData", data)
--   MDMDialogLoader.cleanup()   -- call on FSBaseMission.delete

MDMDialogLoader = MDMDialogLoader or {}

MDMDialogLoader._registry = {}   -- name -> { class, xmlPath, instance, loaded }
MDMDialogLoader._modDir   = nil

function MDMDialogLoader.init(modDir)
    MDMDialogLoader._modDir = modDir
end

function MDMDialogLoader.register(name, class, xmlRelPath)
    MDMDialogLoader._registry[name] = {
        class    = class,
        xmlPath  = xmlRelPath,
        instance = nil,
        loaded   = false,
    }
    MDMLog.info("MDMDialogLoader: registered '" .. name .. "'")
end

local function _ensureLoaded(name)
    local entry = MDMDialogLoader._registry[name]
    if not entry then
        MDMLog.warn("MDMDialogLoader: dialog '" .. tostring(name) .. "' not registered")
        return false
    end
    if entry.loaded then
        MDMLog.info("MDMDialogLoader: '" .. name .. "' already loaded, skipping loadGui")
        return true
    end
    if not g_gui then
        MDMLog.warn("MDMDialogLoader: g_gui not ready when loading '" .. name .. "'")
        return false
    end
    local modDir = MDMDialogLoader._modDir
    if not modDir then
        MDMLog.warn("MDMDialogLoader: modDir not set (call init first)")
        return false
    end
    local xmlPath = modDir .. entry.xmlPath
    MDMLog.info("MDMDialogLoader: loading '" .. name .. "' from: " .. xmlPath)
    local ok, err = pcall(function()
        local inst = entry.class.new()
        MDMLog.info("MDMDialogLoader: instance created, calling g_gui:loadGui ...")
        g_gui:loadGui(xmlPath, name, inst)
        MDMLog.info("MDMDialogLoader: loadGui returned OK")
        entry.instance = inst
        entry.loaded   = true
    end)
    if not ok then
        MDMLog.warn("MDMDialogLoader: failed to load '" .. name .. "': " .. tostring(err))
        return false
    end
    MDMLog.info("MDMDialogLoader: '" .. name .. "' loaded OK")
    return true
end

--- Show a dialog, optionally calling a data-setter before g_gui:showDialog().
function MDMDialogLoader.show(name, dataMethod, ...)
    MDMLog.info("MDMDialogLoader.show: called for '" .. tostring(name) .. "'")
    if not _ensureLoaded(name) then
        MDMLog.warn("MDMDialogLoader.show: _ensureLoaded failed for '" .. tostring(name) .. "'")
        return false
    end
    local entry = MDMDialogLoader._registry[name]
    if not entry or not entry.instance then
        MDMLog.warn("MDMDialogLoader.show: no instance for '" .. tostring(name) .. "'")
        return false
    end
    if dataMethod and entry.instance[dataMethod] then
        MDMLog.info("MDMDialogLoader.show: calling " .. name .. ":" .. dataMethod .. "()")
        local ok, err = pcall(entry.instance[dataMethod], entry.instance, ...)
        if not ok then
            MDMLog.warn("MDMDialogLoader: " .. name .. ":" .. dataMethod .. "() error: " .. tostring(err))
        end
    end
    -- Secondary guard: if the dialog is open OR pending open (showDialog called but
    -- onOpen hasn't fired yet), skip. _isPending is set synchronously here so it
    -- blocks re-entrant calls even within the same frame.
    if entry.instance.isOpen or entry.instance._isPending then
        MDMLog.info("MDMDialogLoader.show: '" .. name .. "' already open/pending — skipping showDialog")
        return false
    end
    entry.instance._isPending = true
    MDMLog.info("MDMDialogLoader.show: calling g_gui:showDialog('" .. name .. "') ...")
    local ok, err = pcall(g_gui.showDialog, g_gui, name)
    if not ok then
        MDMLog.warn("MDMDialogLoader: showDialog('" .. name .. "') error: " .. tostring(err))
        return false
    end
    MDMLog.info("MDMDialogLoader.show: showDialog returned OK")
    return true
end

--- Get the dialog instance (for direct queries).
function MDMDialogLoader.getDialog(name)
    local entry = MDMDialogLoader._registry[name]
    return entry and entry.instance or nil
end

--- Close a dialog by name.
function MDMDialogLoader.close(name)
    local entry = MDMDialogLoader._registry[name]
    if entry and entry.instance then
        pcall(entry.instance.close, entry.instance)
    end
end

--- Unload all dialogs (call on FSBaseMission.delete).
function MDMDialogLoader.cleanup()
    for _, entry in pairs(MDMDialogLoader._registry) do
        if entry.instance then
            pcall(entry.instance.close, entry.instance)
        end
        entry.instance = nil
        entry.loaded   = false
    end
end