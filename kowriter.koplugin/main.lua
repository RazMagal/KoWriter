--[[--
KoWriter — write/draw on documents with a stylus (or finger) in KOReader.

Purpose: give Android e-readers (Onyx BOOX, Bigme, etc.) the "ink on the page"
experience of their built-in notes app, which KOReader lacks natively.

How it works (see README.md for the full story):
  * Input: on Android the pen arrives as an ordinary touch. We tap the raw touch
    stream by wrapping Device.input.gesture_detector.feedEvent (the same trick
    notes.koplugin uses) so we get every point at full rate, before it becomes a
    tap/swipe. While write mode is ON we swallow those events so the reader does
    not turn pages under the pen.
  * Rendering: we register as a ReaderView "view module", so paintTo() is called
    on every page repaint and draws the saved ink on top of the page.
  * Storage: strokes are kept per page and written to the document's sidecar
    directory, so ink reappears when you come back to a page or reopen the book.

Scope of v1: freehand pen, eraser, undo, clear, a few colors and widths, and an
on-page toolbar. Strokes are stored in screen coordinates keyed by page number
(good for fixed-layout PDF and for reading at a stable font size; ink may shift
if you later change font size / zoom / rotation — a known limitation shared with
pencil.koplugin).

@module koplugin.kowriter
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local RenderText = require("ui/rendertext")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local dump = require("dump")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

-- KoWriter is only meaningful on a touch device (the pen/finger draws).
if not Device:isTouchDevice() then
    return { disabled = true }
end

-- Tool identifiers.
local TOOL_PEN = "pen"
local TOOL_ERASER = "eraser"

-- Linux ABS_MT_TOOL_TYPE values, mirrored by the optional input_android patch.
-- On stock Android these are always nil (finger), so both pen and finger draw.
local MT_TOOL_FINGER = 0
local MT_TOOL_PEN = 1

-- Palette. Kept small; on a grayscale panel the non-black entries render as
-- gray, which is still useful for distinguishing layers of notes.
local COLORS = {
    { name = "Black",  color = Blitbuffer.COLOR_BLACK },
    { name = "Red",    color = Blitbuffer.ColorRGB32(0xE0, 0x20, 0x10, 0xFF) },
    { name = "Blue",   color = Blitbuffer.ColorRGB32(0x10, 0x50, 0xE0, 0xFF) },
    { name = "Gray",   color = Blitbuffer.Color8(0x80) },
}

local WIDTHS = { 2, 4, 6, 9 }

-- ---------------------------------------------------------------------------
-- Small geometry helpers (inlined so the plugin is a single self-contained
-- module; adapted from pencil.koplugin/lib/geometry.lua).
-- ---------------------------------------------------------------------------

-- Convert a raw hardware touch coordinate into logical (rotated) screen space.
local function transformForRotation(x, y, rotation, w, h)
    if rotation == 1 then          -- clockwise
        return w - y, x
    elseif rotation == 2 then      -- upside down
        return w - x, h - y
    elseif rotation == 3 then      -- counter-clockwise
        return y, h - x
    end
    return x, y                    -- upright (0) or unknown
end

-- True if (px,py) is within `threshold` px of any point of the stroke.
local function isPointNearStroke(px, py, stroke, threshold)
    if not stroke or not stroke.points then return false end
    local t2 = threshold * threshold
    for _, p in ipairs(stroke.points) do
        local dx, dy = px - p.x, py - p.y
        if dx * dx + dy * dy <= t2 then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Plugin
-- ---------------------------------------------------------------------------

local KoWriter = WidgetContainer:extend{
    name = "kowriter",
    is_doc_only = true,
}

function KoWriter:init()
    self.enabled = false            -- "write mode": pen draws, gestures suspended
    self.current_tool = TOOL_PEN
    self.color_index = 1
    self.width_index = 2
    self.pen_only = false           -- ignore finger touches (needs tool-type patch)
    self.raw_coords = false         -- skip rotation transform (device tuning escape)

    self.strokes = {}               -- flat list of all strokes for this document
    self.page_strokes = {}          -- page -> { stroke indices }
    self.undo_stack = {}
    self.contacts = {}              -- slot -> per-contact drawing state
    self.current_stroke = nil
    self.strokes_loaded = false

    self.toolbar_buttons = nil      -- computed rects, valid while enabled

    self:loadSettings()

    -- Draw the ink overlay on every page repaint.
    self.view = self.ui.view
    if self.view and self.view.registerViewModule then
        self.view:registerViewModule("kowriter", self)
    end

    self.ui.menu:registerToMainMenu(self)

    -- Load any saved ink for this document (also retried in onReaderReady).
    if self.ui.doc_settings and self.ui.doc_settings.doc_sidecar_dir then
        self:loadStrokes()
    end

    -- A mappable action so users can bind "toggle write mode" to a gesture or
    -- a hardware key (Gear -> Taps and gestures).
    Dispatcher:registerAction("kowriter_toggle", {
        category = "none",
        event = "KoWriterToggle",
        title = _("KoWriter: toggle write mode"),
        reader = true,
    })

    logger.info("KoWriter: initialized")
end

-- --- Settings (global; write mode itself is intentionally not persisted) -----

function KoWriter:loadSettings()
    local s = G_reader_settings:readSetting("kowriter_settings") or {}
    self.color_index = s.color_index or self.color_index
    self.width_index = s.width_index or self.width_index
    self.pen_only = s.pen_only or false
    self.raw_coords = s.raw_coords or false
end

function KoWriter:saveSettings()
    G_reader_settings:saveSetting("kowriter_settings", {
        color_index = self.color_index,
        width_index = self.width_index,
        pen_only = self.pen_only,
        raw_coords = self.raw_coords,
    })
end

-- --- Enable / disable write mode --------------------------------------------

function KoWriter:onKoWriterToggle()
    self:setEnabled(not self.enabled)
    return true
end

function KoWriter:setEnabled(on)
    if on == self.enabled then return end
    self.enabled = on
    if on then
        self:installInputHook()
        self:computeToolbar()
    else
        self:removeInputHook()
        self:flushCurrentStroke()
        self.toolbar_buttons = nil
    end
    -- Full repaint so the toolbar and any in-flight ink settle cleanly.
    UIManager:setDirty(self.view, "ui")
end

-- --- Raw input capture -------------------------------------------------------
-- We wrap the gesture detector's feedEvent. It is called once per input frame
-- with the array of touch slots; each slot is {slot,id,x,y,tool,timev} with
-- id == -1 meaning "lifted". This is the earliest point at which we can see
-- raw, high-rate points on Android, and returning an empty gesture list
-- suppresses the page-turn/menu gestures that would otherwise fire.

function KoWriter:installInputHook()
    local gd = Device.input and Device.input.gesture_detector
    if not gd or self._orig_feedEvent then return end
    self._orig_feedEvent = gd.feedEvent
    local plugin = self
    local orig = self._orig_feedEvent
    gd.feedEvent = function(gdself, slots)
        local swallow = plugin:handleSlots(slots)
        if swallow then
            return {}   -- no gestures -> reader ignores this frame
        end
        return orig(gdself, slots)
    end
    logger.info("KoWriter: input hook installed")
end

function KoWriter:removeInputHook()
    local gd = Device.input and Device.input.gesture_detector
    if gd and self._orig_feedEvent then
        gd.feedEvent = self._orig_feedEvent
    end
    self._orig_feedEvent = nil
    self.contacts = {}
    -- Reset the detector so a half-seen contact does not confuse it later.
    if Device.input and Device.input.resetState then
        pcall(function() Device.input:resetState() end)
    end
    logger.info("KoWriter: input hook removed")
end

-- True when something (a menu, dialog, popup) is shown on top of the reader.
-- While that's the case we must let input through so those widgets work.
function KoWriter:isOverlayActive()
    local top = UIManager:getTopmostVisibleWidget()
    if not top then return false end
    return (top.name or top.id) ~= "ReaderUI"
end

-- Returns true to swallow the frame (we handled it), false to pass through.
function KoWriter:handleSlots(slots)
    if not self.enabled or type(slots) ~= "table" then return false end
    -- A menu/dialog is up: don't capture, or the user couldn't dismiss it.
    if self:isOverlayActive() then
        self.contacts = {}
        return false
    end
    local handled = false
    for _, ev in ipairs(slots) do
        if ev and ev.slot ~= nil then
            local down = (ev.id ~= nil and ev.id ~= -1)
            local x, y = self:mapCoords(ev.x, ev.y)
            if down and x then
                self:onContactDown(ev.slot, x, y, ev.tool)
                handled = true
            elseif down then
                -- coordinate off-screen / unusable; keep the frame ours anyway
                handled = true
            else
                self:onContactUp(ev.slot)
                handled = true
            end
        end
    end
    return handled
end

-- Map a raw slot coordinate to logical screen coordinates.
function KoWriter:mapCoords(x, y)
    if x == nil or y == nil then return nil end
    if self.raw_coords then return x, y end
    local w, h = Screen:getWidth(), Screen:getHeight()
    local rot = Screen:getRotationMode()
    local lx, ly = transformForRotation(x, y, rot, w, h)
    return lx, ly
end

-- New point on a contact (down or move share this path; we key by slot).
function KoWriter:onContactDown(slot, x, y, tool)
    local c = self.contacts[slot]
    if not c then
        -- First sample of a fresh contact: decide what it is.
        -- 1) toolbar hit?
        local action = self:toolbarHit(x, y)
        if action then
            self.contacts[slot] = { mode = "toolbar" }
            self:runToolbarAction(action)
            return
        end
        -- 2) finger, with pen-only enabled and tool info available? ignore.
        if self.pen_only and tool ~= nil and tool ~= MT_TOOL_PEN then
            self.contacts[slot] = { mode = "ignore" }
            return
        end
        -- 3) drawing.
        self.contacts[slot] = { mode = "draw", last_x = x, last_y = y }
        self:strokeStart(x, y)
        return
    end
    if c.mode == "draw" then
        if x ~= c.last_x or y ~= c.last_y then
            self:strokeAppend(c.last_x, c.last_y, x, y)
            c.last_x, c.last_y = x, y
        end
    end
    -- toolbar / ignore contacts do nothing on subsequent samples.
end

function KoWriter:onContactUp(slot)
    local c = self.contacts[slot]
    if c and c.mode == "draw" then
        self:strokeEnd()
    end
    self.contacts[slot] = nil
end

-- --- Stroke building & incremental drawing ----------------------------------

function KoWriter:strokeStart(x, y)
    if self.current_tool == TOOL_ERASER then
        self.current_stroke = nil
        self:eraseAt(x, y)
        return
    end
    self.current_stroke = {
        page = self:getCurrentPage(),
        tool = TOOL_PEN,
        width = WIDTHS[self.width_index],
        color_name = COLORS[self.color_index].name,
        points = { { x = x, y = y } },
        datetime = os.time(),
    }
    -- Draw the initial dot immediately for responsiveness.
    self:paintDot(Screen.bb, x, y, self.current_stroke.width,
        COLORS[self.color_index].color)
    self:refreshRegion(x, y, x, y, self.current_stroke.width)
end

function KoWriter:strokeAppend(x0, y0, x1, y1)
    if self.current_tool == TOOL_ERASER then
        self:eraseAt(x1, y1)
        return
    end
    if not self.current_stroke then return end
    table.insert(self.current_stroke.points, { x = x1, y = y1 })
    local w = self.current_stroke.width
    local color = COLORS[self.color_index].color
    self:paintSegment(Screen.bb, x0, y0, x1, y1, w, color)
    self:refreshRegion(x0, y0, x1, y1, w)
end

function KoWriter:strokeEnd()
    local s = self.current_stroke
    self.current_stroke = nil
    if not s or #s.points < 1 then return end
    table.insert(self.strokes, s)
    self:indexStroke(#self.strokes, s.page)
    table.insert(self.undo_stack, { type = "add", idx = #self.strokes })
    self:saveStrokes()
end

-- Persist an in-progress stroke (used on page change / disable / close).
function KoWriter:flushCurrentStroke()
    if self.current_stroke and #self.current_stroke.points >= 1 then
        self:strokeEnd()
    else
        self.current_stroke = nil
    end
    self.contacts = {}
end

-- --- Low-level painting ------------------------------------------------------

function KoWriter:paintDot(bb, x, y, width, color)
    local h = math.floor(width / 2)
    bb:paintRectRGB32(x - h, y - h, width, width, color)
end

-- Draw a thick line by stepping square brushes along it (matches the approach
-- pencil.koplugin uses; robust across blitbuffer pixel formats).
function KoWriter:paintSegment(bb, x1, y1, x2, y2, width, color)
    local dx, dy = x2 - x1, y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    local h = math.floor(width / 2)
    if dist < 1 then
        bb:paintRectRGB32(x1 - h, y1 - h, width, width, color)
        return
    end
    local steps = math.ceil(dist)
    for i = 0, steps do
        local t = i / steps
        local x = math.floor(x1 + dx * t)
        local y = math.floor(y1 + dy * t)
        bb:paintRectRGB32(x - h, y - h, width, width, color)
    end
end

-- Fast partial refresh of the bounding box we just drew into, padded for the
-- brush width. Keeps ink latency low on e-ink.
function KoWriter:refreshRegion(x1, y1, x2, y2, width)
    local pad = width + 4
    local rx = math.max(0, math.min(x1, x2) - pad)
    local ry = math.max(0, math.min(y1, y2) - pad)
    local rw = math.abs(x2 - x1) + pad * 2
    local rh = math.abs(y2 - y1) + pad * 2
    rw = math.min(Screen:getWidth() - rx, rw)
    rh = math.min(Screen:getHeight() - ry, rh)
    if rw > 0 and rh > 0 then
        Screen:refreshUI(rx, ry, rw, rh)
    end
end

-- --- Eraser ------------------------------------------------------------------

function KoWriter:eraseAt(x, y)
    local page = self:getCurrentPage()
    local indices = self.page_strokes[page]
    if not indices then return end
    local threshold = math.max(12, WIDTHS[self.width_index] * 3)
    local removed = {}
    for _, i in ipairs(indices) do
        local s = self.strokes[i]
        if s and isPointNearStroke(x, y, s, threshold) then
            table.insert(removed, s)
        end
    end
    if #removed == 0 then return end
    -- Rebuild the flat list without the removed strokes.
    local keep = {}
    local removed_set = {}
    for _, s in ipairs(removed) do removed_set[s] = true end
    for _, s in ipairs(self.strokes) do
        if not removed_set[s] then table.insert(keep, s) end
    end
    self.strokes = keep
    self:rebuildPageIndex()
    table.insert(self.undo_stack, { type = "delete", strokes = removed })
    self:saveStrokes()
    -- Repaint the page cleanly so erased ink actually disappears from e-ink.
    UIManager:setDirty(self.view, "ui")
end

-- --- View module: paint saved ink (and the toolbar) on every repaint --------

function KoWriter:paintTo(bb, x, y)
    local page = self:getCurrentPage()
    local indices = self.page_strokes[page]
    if indices then
        for _, idx in ipairs(indices) do
            self:renderStroke(bb, self.strokes[idx])
        end
    end
    if self.current_stroke and self.current_stroke.page == page then
        self:renderStroke(bb, self.current_stroke)
    end
    if self.enabled then
        self:paintToolbar(bb)
    end
end

function KoWriter:renderStroke(bb, s)
    if not s or not s.points or #s.points < 1 then return end
    local color = Blitbuffer.COLOR_BLACK
    for _, c in ipairs(COLORS) do
        if c.name == s.color_name then color = c.color break end
    end
    local w = s.width or 4
    if #s.points == 1 then
        self:paintDot(bb, s.points[1].x, s.points[1].y, w, color)
    else
        for i = 2, #s.points do
            local p1, p2 = s.points[i - 1], s.points[i]
            self:paintSegment(bb, p1.x, p1.y, p2.x, p2.y, w, color)
        end
    end
end

-- --- On-page toolbar (painted by us, hit-tested in the input hook) -----------

function KoWriter:computeToolbar()
    local sw = Screen:getWidth()
    local bh = Screen:scaleBySize(46)
    local labels = self:toolbarLabels()
    local n = #labels
    local bw = math.min(Screen:scaleBySize(78), math.floor(sw / n))
    local buttons = {}
    for i, item in ipairs(labels) do
        buttons[i] = {
            action = item.action,
            label = item.label,
            x = (i - 1) * bw,
            y = 0,
            w = bw,
            h = bh,
        }
    end
    self.toolbar_buttons = buttons
    self.toolbar_height = bh
end

function KoWriter:toolbarLabels()
    local tool = self.current_tool == TOOL_PEN and "Pen" or "Erase"
    return {
        { action = "exit",  label = "Done" },
        { action = "tool",  label = tool },
        { action = "color", label = COLORS[self.color_index].name },
        { action = "width", label = "W" .. WIDTHS[self.width_index] },
        { action = "undo",  label = "Undo" },
        { action = "clear", label = "Clear" },
        { action = "prev",  label = "<" },
        { action = "next",  label = ">" },
    }
end

function KoWriter:toolbarHit(x, y)
    if not self.toolbar_buttons then return nil end
    for _, b in ipairs(self.toolbar_buttons) do
        if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then
            return b.action
        end
    end
    return nil
end

function KoWriter:paintToolbar(bb)
    if not self.toolbar_buttons then self:computeToolbar() end
    local face = Font:getFace("cfont", 17)
    for _, b in ipairs(self.toolbar_buttons) do
        -- White button with a black border.
        bb:paintRectRGB32(b.x, b.y, b.w, b.h, Blitbuffer.COLOR_WHITE)
        self:strokeRect(bb, b.x, b.y, b.w, b.h, 2, Blitbuffer.COLOR_BLACK)
        -- Highlight the active tool button.
        if b.action == "tool" and self.current_tool == TOOL_ERASER then
            self:strokeRect(bb, b.x + 2, b.y + 2, b.w - 4, b.h - 4, 2,
                Blitbuffer.COLOR_BLACK)
        end
        local tw = RenderText:sizeUtf8Text(0, b.w, face, b.label, true).x
        local tx = b.x + math.max(2, math.floor((b.w - tw) / 2))
        local ty = b.y + math.floor(b.h / 2) + Screen:scaleBySize(6)
        RenderText:renderUtf8Text(bb, tx, ty, face, b.label, true,
            nil, Blitbuffer.COLOR_BLACK)
    end
end

function KoWriter:strokeRect(bb, x, y, w, h, t, color)
    bb:paintRectRGB32(x, y, w, t, color)
    bb:paintRectRGB32(x, y + h - t, w, t, color)
    bb:paintRectRGB32(x, y, t, h, color)
    bb:paintRectRGB32(x + w - t, y, t, h, color)
end

function KoWriter:runToolbarAction(action)
    if action == "exit" then
        self:setEnabled(false)
        return
    elseif action == "tool" then
        self.current_tool = (self.current_tool == TOOL_PEN) and TOOL_ERASER or TOOL_PEN
    elseif action == "color" then
        self.color_index = (self.color_index % #COLORS) + 1
        self:saveSettings()
    elseif action == "width" then
        self.width_index = (self.width_index % #WIDTHS) + 1
        self:saveSettings()
    elseif action == "undo" then
        self:undo()
    elseif action == "clear" then
        self:clearPage()
    elseif action == "prev" then
        self:flushCurrentStroke()
        self.ui:handleEvent(Event:new("GotoViewRel", -1))
    elseif action == "next" then
        self:flushCurrentStroke()
        self.ui:handleEvent(Event:new("GotoViewRel", 1))
    end
    self:computeToolbar()          -- labels may have changed
    UIManager:setDirty(self.view, "ui")
end

-- --- Undo / clear ------------------------------------------------------------

function KoWriter:undo()
    local a = table.remove(self.undo_stack)
    if not a then return end
    if a.type == "add" then
        if self.strokes[a.idx] then
            table.remove(self.strokes, a.idx)
        end
    elseif a.type == "delete" then
        for _, s in ipairs(a.strokes) do
            table.insert(self.strokes, s)
        end
    end
    self:rebuildPageIndex()
    self:saveStrokes()
    UIManager:setDirty(self.view, "ui")
end

function KoWriter:clearPage()
    local page = self:getCurrentPage()
    local indices = self.page_strokes[page]
    if not indices or #indices == 0 then return end
    local removed_set = {}
    for _, i in ipairs(indices) do removed_set[self.strokes[i]] = true end
    local keep, removed = {}, {}
    for _, s in ipairs(self.strokes) do
        if removed_set[s] then table.insert(removed, s)
        else table.insert(keep, s) end
    end
    self.strokes = keep
    self:rebuildPageIndex()
    table.insert(self.undo_stack, { type = "delete", strokes = removed })
    self:saveStrokes()
    UIManager:setDirty(self.view, "ui")
end

function KoWriter:clearAll()
    self.strokes = {}
    self.page_strokes = {}
    self.undo_stack = {}
    self:saveStrokes()
    UIManager:setDirty(self.view, "ui")
end

-- --- Page indexing -----------------------------------------------------------

function KoWriter:getCurrentPage()
    if self.ui.paging then
        return self.view.state and self.view.state.page or 1
    end
    -- Rolling (EPUB): use a stable page number derived from the reading position.
    local ok, xp = pcall(function() return self.ui.document:getXPointer() end)
    if ok and xp and self.ui.document.getPageFromXPointer then
        local ok2, p = pcall(function()
            return self.ui.document:getPageFromXPointer(xp)
        end)
        if ok2 and p then return p end
    end
    return 1
end

function KoWriter:indexStroke(idx, page)
    if not self.page_strokes[page] then self.page_strokes[page] = {} end
    table.insert(self.page_strokes[page], idx)
end

function KoWriter:rebuildPageIndex()
    self.page_strokes = {}
    for i, s in ipairs(self.strokes) do
        self:indexStroke(i, s.page)
    end
end

function KoWriter:hasStrokesOnCurrentPage()
    local indices = self.page_strokes[self:getCurrentPage()]
    return indices and #indices > 0
end

-- --- Persistence -------------------------------------------------------------

function KoWriter:getStrokesFilePath()
    if not (self.ui and self.ui.doc_settings) then return nil end
    local dir = self.ui.doc_settings.doc_sidecar_dir
    if not dir then return nil end
    return dir .. "/kowriter_strokes.lua"
end

function KoWriter:loadStrokes()
    local path = self:getStrokesFilePath()
    if not path then return end
    local f = io.open(path, "r")
    if not f then
        self.strokes = {}
        self.page_strokes = {}
        self.strokes_loaded = true
        return
    end
    f:close()
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" and data.strokes then
        self.strokes = data.strokes
        self:rebuildPageIndex()
        logger.info("KoWriter: loaded", #self.strokes, "strokes")
    else
        logger.warn("KoWriter: failed to load strokes:", tostring(data))
        self.strokes = {}
        self.page_strokes = {}
    end
    self.strokes_loaded = true
end

function KoWriter:saveStrokes()
    local path = self:getStrokesFilePath()
    if not path then return end
    -- Avoid clobbering an existing file with an empty set before we ever loaded.
    if #self.strokes == 0 and not self.strokes_loaded then return end
    local dir = self.ui.doc_settings.doc_sidecar_dir
    if dir then
        local ok, err = lfs.mkdir(dir)
        if not ok and err ~= "File exists" then
            logger.warn("KoWriter: mkdir sidecar failed:", err)
        end
    end
    local f, err = io.open(path, "w")
    if not f then
        logger.err("KoWriter: cannot write strokes:", err)
        return
    end
    f:write("return " .. dump({ version = 1, strokes = self.strokes }))
    f:close()
end

-- --- Lifecycle ---------------------------------------------------------------

function KoWriter:onReaderReady()
    if not self.strokes_loaded then self:loadStrokes() end
end

function KoWriter:onPageUpdate()
    -- Persist in-progress ink to the page it was drawn on before we leave it.
    self:flushCurrentStroke()
end

function KoWriter:onUpdatePos()
    self:flushCurrentStroke()
end

function KoWriter:onCloseDocument()
    self:flushCurrentStroke()
    self:removeInputHook()
    self:saveStrokes()
end

function KoWriter:onSuspend()
    self:flushCurrentStroke()
    self:saveStrokes()
end

-- --- Menu --------------------------------------------------------------------

function KoWriter:addToMainMenu(menu_items)
    menu_items.kowriter = {
        text = _("KoWriter"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Write mode"),
                help_text = _("When on, the pen/finger draws on the page and normal reading gestures are suspended. Use the on-page toolbar's Done button (or this toggle) to leave."),
                checked_func = function() return self.enabled end,
                callback = function() self:setEnabled(not self.enabled) end,
                separator = true,
            },
            {
                text_func = function()
                    return T(_("Pen color: %1"), COLORS[self.color_index].name)
                end,
                callback = function()
                    self.color_index = (self.color_index % #COLORS) + 1
                    self:saveSettings()
                    if self.enabled then self:computeToolbar() end
                end,
            },
            {
                text_func = function()
                    return T(_("Pen width: %1"), WIDTHS[self.width_index])
                end,
                callback = function()
                    self.width_index = (self.width_index % #WIDTHS) + 1
                    self:saveSettings()
                    if self.enabled then self:computeToolbar() end
                end,
                separator = true,
            },
            {
                text = _("Pen only (ignore finger)"),
                help_text = _("Ignore finger touches so your palm does not draw. Requires the optional input_android tool-type patch (see README); without it, finger and pen are indistinguishable and this has no effect."),
                checked_func = function() return self.pen_only end,
                callback = function()
                    self.pen_only = not self.pen_only
                    self:saveSettings()
                end,
            },
            {
                text = _("Raw coordinates (no rotation fix)"),
                help_text = _("Turn on only if your ink lands in the wrong place. Toggles whether touch coordinates are rotated to match the screen orientation."),
                checked_func = function() return self.raw_coords end,
                callback = function()
                    self.raw_coords = not self.raw_coords
                    self:saveSettings()
                end,
                separator = true,
            },
            {
                text = _("Undo last stroke"),
                enabled_func = function() return #self.undo_stack > 0 end,
                callback = function() self:undo() end,
            },
            {
                text = _("Clear this page"),
                enabled_func = function() return self:hasStrokesOnCurrentPage() end,
                callback = function() self:clearPage() end,
            },
            {
                text = _("Clear all ink in this book"),
                enabled_func = function() return #self.strokes > 0 end,
                callback = function(touchmenu_instance)
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete all KoWriter ink in this book? This cannot be undone."),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            self:clearAll()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
                separator = true,
            },
            {
                text = _("About / status"),
                keep_menu_open = true,
                callback = function() self:showStatus() end,
            },
        },
    }
end

function KoWriter:showStatus()
    local page = self:getCurrentPage()
    local on_page = self.page_strokes[page] and #self.page_strokes[page] or 0
    local hooked = self._orig_feedEvent ~= nil
    UIManager:show(InfoMessage:new{
        text = T(_([[KoWriter

Write mode: %1
Tool: %2
Color: %3   Width: %4
Pen only: %5
Input hook active: %6

Current page: %7
Ink on this page: %8
Total strokes in book: %9

Storage: %10]]),
            self.enabled and _("ON") or _("off"),
            self.current_tool,
            COLORS[self.color_index].name,
            WIDTHS[self.width_index],
            self.pen_only and _("yes") or _("no"),
            hooked and _("yes") or _("no"),
            tostring(page),
            on_page,
            #self.strokes,
            self:getStrokesFilePath() or _("unavailable")),
    })
end

return KoWriter
