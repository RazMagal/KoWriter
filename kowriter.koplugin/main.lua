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
local util = require("util")
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

-- Linux ABS_MT_TOOL_TYPE value for a finger, as exposed by the optional
-- input_android tool-type patch. On stock Android the tool type is never
-- reported (tool == nil), so pen and finger are indistinguishable and both
-- draw; only a patched device reports this, letting us drop finger/palm touches.
local MT_TOOL_FINGER = 0

-- Palette. Kept small; on a grayscale panel the non-black entries render as
-- gray, which is still useful for distinguishing layers of notes.
local COLORS = {
    { name = "Black",  color = Blitbuffer.COLOR_BLACK },
    { name = "Red",    color = Blitbuffer.ColorRGB32(0xE0, 0x20, 0x10, 0xFF) },
    { name = "Blue",   color = Blitbuffer.ColorRGB32(0x10, 0x50, 0xE0, 0xFF) },
    { name = "Gray",   color = Blitbuffer.Color8(0x80) },
}

local WIDTHS = { 2, 4, 6, 9 }

-- Stroke file format version; bump when the on-disk shape changes. A file with
-- a NEWER version than this is left untouched (never overwritten) so a
-- downgraded build can't wipe ink written by a newer one.
local STROKES_FORMAT_VERSION = 1

-- Cap the undo history so deleted stroke tables don't accumulate all session.
local UNDO_LIMIT = 100

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
    self.raw_coords = false         -- skip rotation transform (device tuning escape)
    self.offset_x = 0               -- manual calibration nudge (logical px)
    self.offset_y = 0

    self.strokes = {}               -- flat list of all strokes for this document
    self.page_strokes = {}          -- page -> { stroke indices }
    self.undo_stack = {}
    self.contacts = {}              -- slot -> per-contact drawing state (incl. its own in-progress stroke)
    self.strokes_loaded = false
    self.load_failed = false        -- strokes file unreadable: refuse to overwrite it
    self._pending_unhook = false    -- write mode off, waiting for contacts to lift
    self._save_scheduled = false
    self._save_warned = false
    self._scroll_warned = false
    self._reader_ready = false
    self._pending_msg = nil
    self._migrate_from = nil        -- legacy sidecar to set aside after next save

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
    -- Settings can come from a build with a different palette; clamp so an
    -- out-of-range index can't crash COLORS[...]/WIDTHS[...] lookups.
    if not COLORS[self.color_index] then self.color_index = 1 end
    if not WIDTHS[self.width_index] then self.width_index = 2 end
    self.raw_coords = s.raw_coords or false
    self.offset_x = s.offset_x or 0
    self.offset_y = s.offset_y or 0
end

function KoWriter:saveSettings()
    G_reader_settings:saveSetting("kowriter_settings", {
        color_index = self.color_index,
        width_index = self.width_index,
        raw_coords = self.raw_coords,
        offset_x = self.offset_x,
        offset_y = self.offset_y,
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
        self._pending_unhook = false
        -- A watchdog queued by an earlier disable must not fire into this
        -- new enable cycle and yank the hook out from under the pen.
        if self._unhook_watchdog then
            UIManager:unschedule(self._unhook_watchdog)
        end
        self:installInputHook()
        self:computeToolbar()
    else
        -- Flush BEFORE removing the hook, so a stroke left unfinished at
        -- toggle-off is committed.
        self:flushCurrentStroke()
        self:saveStrokes()
        -- If a contact is still physically down (the pen that just tapped
        -- "Done"), removing the hook now would hand its lift to KOReader as a
        -- fresh tap in the menu/page-turn zone. Keep swallowing frames until
        -- every contact lifts; onContactUp() removes the hook then.
        if next(self.contacts) then
            self._pending_unhook = true
            -- Escape hatch: if the lift is never delivered (phantom contact,
            -- suspend mid-tap), don't leave the hook eating all input forever.
            -- Accepted residual: holding the pen down > 3 s after tapping Done
            -- also fires this and hands the eventual lift to KOReader.
            self._unhook_watchdog = self._unhook_watchdog or function()
                if self._pending_unhook then
                    logger.warn("KoWriter: unhook watchdog fired (missed contact lift)")
                    self:removeInputHook()
                end
            end
            UIManager:unschedule(self._unhook_watchdog)
            UIManager:scheduleIn(3, self._unhook_watchdog)
        else
            self:removeInputHook()
        end
        self.toolbar_buttons = nil
    end
    -- Full repaint so the toolbar and any in-flight ink settle cleanly.
    self:requestRefresh(true)
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
    self._hook_fn = function(gdself, slots)
        local swallow = plugin:handleSlots(slots)
        if swallow then
            return {}   -- no gestures -> reader ignores this frame
        end
        return orig(gdself, slots)
    end
    gd.feedEvent = self._hook_fn
    logger.info("KoWriter: input hook installed")
end

function KoWriter:removeInputHook()
    local gd = Device.input and Device.input.gesture_detector
    if gd and self._orig_feedEvent then
        -- Only restore if our wrapper is still the active hook. If another
        -- plugin wrapped feedEvent after us, blindly restoring our saved
        -- original would silently discard that plugin's wrapper.
        if gd.feedEvent == self._hook_fn then
            gd.feedEvent = self._orig_feedEvent
        else
            logger.warn("KoWriter: feedEvent was re-wrapped after us; leaving it in place")
        end
    end
    self._orig_feedEvent = nil
    self._hook_fn = nil
    self._pending_unhook = false
    if self._unhook_watchdog then
        UIManager:unschedule(self._unhook_watchdog)
    end
    self.contacts = {}
    -- Reset the detector so a half-seen contact does not confuse it later.
    if Device.input and Device.input.resetState then
        pcall(function() Device.input:resetState() end)
    end
    logger.info("KoWriter: input hook removed")
end

-- True while our wrapper really is the live feedEvent (not merely "we
-- installed at some point") — this is what About/status reports.
function KoWriter:isHookActive()
    local gd = Device.input and Device.input.gesture_detector
    return gd ~= nil and self._hook_fn ~= nil and gd.feedEvent == self._hook_fn
end

-- True when something (a menu, dialog, popup) is shown on top of the reader.
-- While that's the case we must let input through so those widgets work.
--
-- Deliberately coarse: ANY topmost widget that isn't ReaderUI releases the
-- pen. Trying to carve out "harmless" anonymous widgets (transient toasts)
-- was tested and is unsafe — KOReader's TouchMenu container is itself
-- anonymous (no name/id/modal/covers_fullscreen), so the carve-out swallowed
-- the user's menu taps and drew dots instead (verified on hardware). The cost
-- is only that a stray toast mid-stroke flushes the stroke and lets input
-- through until it times out — rare and recoverable.
function KoWriter:isOverlayActive()
    local top = UIManager:getTopmostVisibleWidget()
    if not top then return false end
    return (top.name or top.id) ~= "ReaderUI"
end

-- Returns true to swallow the frame (we handled it), false to pass through.
function KoWriter:handleSlots(slots)
    if not (self.enabled or self._pending_unhook) or type(slots) ~= "table" then
        return false
    end
    -- A menu/dialog is up: don't capture, or the user couldn't dismiss it.
    -- Commit any in-progress ink first so a stroke isn't lost if a popup
    -- appears mid-line.
    if self.enabled and self:isOverlayActive() then
        self:flushCurrentStroke()
        -- We're passing this frame through, so onContactUp will not see any
        -- lift it contains. Drop lifted slots here, or the stale entry would
        -- make the slot's next (fresh) contact look like a continuation and
        -- silently swallow a whole stroke.
        for _, ev in ipairs(slots) do
            if ev and ev.slot ~= nil and (ev.id == nil or ev.id == -1) then
                self.contacts[ev.slot] = nil
            end
        end
        return false
    end
    local handled = false
    for _, ev in ipairs(slots) do
        if ev and ev.slot ~= nil then
            local down = (ev.id ~= nil and ev.id ~= -1)
            local x, y = self:mapCoords(ev.x, ev.y)
            if down and x then
                if self._pending_unhook then
                    -- Write mode is already off; we're only riding out the
                    -- contacts that were down when it was turned off. Swallow
                    -- their frames (and any newcomer's) without drawing.
                    if not self.contacts[ev.slot] then
                        self.contacts[ev.slot] = { mode = "ignore" }
                    end
                else
                    self:onContactDown(ev.slot, x, y, ev.tool)
                end
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
--
-- KOReader itself receives these same raw (device scale/mirror/translate already
-- applied) coordinates in gesture_detector:feedEvent and only rotates them
-- *afterwards*, in GestureDetector:translateCoordinates, using the screen's
-- getTouchRotation() -- NOT getRotationMode(). The two are equal on most panels
-- but a device may override getTouchRotation() when the digitizer axes are
-- desynced from the display (forced/native rotation), so we mirror KOReader's
-- exact choice to keep ink under the pen in every orientation. The formulas in
-- transformForRotation are the same ones translateCoordinates uses.
function KoWriter:mapCoords(x, y)
    if x == nil or y == nil then return nil end
    if self.raw_coords then
        return x + self.offset_x, y + self.offset_y
    end
    local w, h = Screen:getWidth(), Screen:getHeight()
    local rot = Screen.getTouchRotation and Screen:getTouchRotation()
        or Screen:getRotationMode()
    local lx, ly = transformForRotation(x, y, rot, w, h)
    return lx + self.offset_x, ly + self.offset_y
end

-- New point on a contact (down or move share this path; we key by slot).
--
-- Each contact owns its own in-progress stroke (c.stroke). This is deliberate:
-- with a single shared stroke, a second contact landing mid-line -- a resting
-- palm, or a phantom touch from a flaky/cracked digitizer -- would hijack the
-- pen's stroke and make the ink jump between the pen and the spurious point.
-- Isolating strokes per contact means a stray touch draws its own (ignorable)
-- mark instead of corrupting what you're actually writing.
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
        -- 2) a touch the device explicitly reports as a finger? drop it (palm
        -- rejection). This only fires when tool-type is available, i.e. on a
        -- device with the optional input_android patch; on stock Android tool is
        -- nil, so fingers draw just like the pen (there's no way to tell them
        -- apart). No user setting -- it's automatic when the data exists.
        if tool == MT_TOOL_FINGER then
            self.contacts[slot] = { mode = "ignore" }
            return
        end
        -- 3) eraser: no stroke, just remove ink under each sample.
        if self.current_tool == TOOL_ERASER then
            c = { mode = "erase", last_x = x, last_y = y }
            self.contacts[slot] = c
            self:eraseAt(x, y, c)
            return
        end
        -- 4) pen: start this contact's own stroke.
        c = { mode = "draw", last_x = x, last_y = y, stroke = self:newStroke(x, y) }
        self.contacts[slot] = c
        -- Draw the initial dot immediately for responsiveness.
        self:paintDot(Screen.bb, x, y, c.stroke.width, self:strokeColor(c.stroke))
        self:refreshRegion(x, y, x, y, c.stroke.width)
        return
    end
    if c.mode == "draw" then
        if x ~= c.last_x or y ~= c.last_y then
            self:appendToStroke(c.stroke, c.last_x, c.last_y, x, y)
            c.last_x, c.last_y = x, y
        end
    elseif c.mode == "erase" then
        if x ~= c.last_x or y ~= c.last_y then
            self:eraseAt(x, y, c)
            c.last_x, c.last_y = x, y
        end
    end
    -- toolbar / ignore contacts do nothing on subsequent samples.
end

function KoWriter:onContactUp(slot)
    local c = self.contacts[slot]
    if c and c.mode == "draw" and c.stroke then
        self:finishStroke(c.stroke)
    elseif c and c.mode == "erase" and c.erased then
        -- Batched eraser commit: one save and one clean (flashing) repaint per
        -- eraser drag, instead of a full save + full repaint per sample.
        self:saveStrokes()
        self:renderNow(true)
    end
    self.contacts[slot] = nil
    -- Write mode was turned off while this contact was down; once the last
    -- contact lifts, it is finally safe to hand input back to KOReader.
    if self._pending_unhook and not next(self.contacts) then
        self:removeInputHook()
    end
end

-- --- Stroke building & incremental drawing ----------------------------------

-- Resolve a stroke's stored color name to a Blitbuffer color (falls back to
-- black so a stroke saved with an old/unknown color still renders).
function KoWriter:strokeColor(stroke)
    for _, c in ipairs(COLORS) do
        if c.name == stroke.color_name then return c.color end
    end
    return Blitbuffer.COLOR_BLACK
end

function KoWriter:newStroke(x, y)
    return {
        page = self:getCurrentPage(),
        tool = TOOL_PEN,
        width = WIDTHS[self.width_index],
        color_name = COLORS[self.color_index].name,
        points = { { x = x, y = y } },
        datetime = os.time(),
    }
end

function KoWriter:appendToStroke(stroke, x0, y0, x1, y1)
    if not stroke then return end
    table.insert(stroke.points, { x = x1, y = y1 })
    local color = self:strokeColor(stroke)
    self:paintSegment(Screen.bb, x0, y0, x1, y1, stroke.width, color)
    self:refreshRegion(x0, y0, x1, y1, stroke.width)
end

function KoWriter:finishStroke(stroke)
    if not stroke or #stroke.points < 1 then return end
    table.insert(self.strokes, stroke)
    self:indexStroke(#self.strokes, stroke.page)
    -- Store the stroke object itself, not its list index: erase/clear rebuild
    -- the flat list and shift indices, which would make an index-based undo
    -- delete the wrong stroke.
    self:pushUndo({ type = "add", stroke = stroke })
    self:scheduleSave()
end

function KoWriter:pushUndo(action)
    table.insert(self.undo_stack, action)
    if #self.undo_stack > UNDO_LIMIT then
        table.remove(self.undo_stack, 1)
    end
end

-- Debounced persistence. saveStrokes() rewrites the whole stroke file, so
-- saving synchronously on every stroke end (and worse, every eraser sample)
-- scales with the ink in the book, not the edit. Leading-edge debounce: the
-- first dirty change schedules a save 2 s out, so exposure is bounded at 2 s
-- even while stroking continuously (a hard app kill inside that window loses
-- at most those 2 s of ink — the deliberate trade). Disable, close, suspend,
-- eraser lift and undo/clear still call saveStrokes() directly, which cancels
-- the pending timer; page turns only flush strokes and ride the debounce.
function KoWriter:scheduleSave()
    if self._save_scheduled then return end
    self._save_scheduled = true
    self._save_cb = self._save_cb or function()
        self._save_scheduled = false
        self:saveStrokes()
    end
    UIManager:scheduleIn(2, self._save_cb)
end

-- Persist every in-progress stroke (used on page change / disable / close).
--
-- Deliberately does NOT delete the slot entries: the contacts may still be
-- physically down, and deleting them would make their next input sample look
-- like a fresh contact — re-firing the toolbar action under a held finger
-- (page turns repeating) or starting a phantom stroke. The entries are
-- switched to "ignore" and removed in onContactUp()/removeInputHook().
function KoWriter:flushCurrentStroke()
    for _, c in pairs(self.contacts) do
        if c.mode == "draw" and c.stroke then
            self:finishStroke(c.stroke)
            c.stroke = nil
            c.mode = "ignore"
        elseif c.mode == "erase" then
            if c.erased then
                self:saveStrokes()
                c.erased = nil
            end
            c.mode = "ignore"
        end
    end
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

-- Repaint the reader (page + our ink + toolbar) straight into the framebuffer
-- and push it to the panel NOW. UIManager:setDirty does not reliably flush
-- while our feedEvent hook is swallowing the touch frame, so toolbar/undo/erase
-- feedback would otherwise not show until the next page turn. This is the same
-- direct path that already makes live drawing appear.
function KoWriter:renderNow(flash)
    if not (self.ui and self.ui.view) then return end
    self.ui.view:paintTo(Screen.bb, 0, 0)
    local w, h = Screen:getWidth(), Screen:getHeight()
    if flash then
        Screen:refreshFull(0, 0, w, h)   -- flashing: cleanly clears removed ink / toolbar
    else
        Screen:refreshUI(0, 0, w, h)
    end
end

-- Refresh the right way for the current context. When a menu/dialog is on top
-- (the action came from the plugin menu), its own close repaints the reader, so
-- a normal setDirty is correct and avoids painting under the closing menu.
-- Otherwise we are in the on-page toolbar / input-hook context and must refresh
-- immediately ourselves.
function KoWriter:requestRefresh(flash)
    if self:isOverlayActive() then
        UIManager:setDirty(self.ui, flash and "full" or "ui")
    else
        self:renderNow(flash)
    end
end

-- --- Eraser ------------------------------------------------------------------

function KoWriter:eraseAt(x, y, contact)
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
    if contact then
        -- One undo entry per eraser drag, not per sample: a single drag that
        -- removes five strokes should be one Undo press, not five.
        if contact.undo_entry then
            for _, s in ipairs(removed) do
                table.insert(contact.undo_entry.strokes, s)
            end
        else
            contact.undo_entry = { type = "delete", strokes = removed }
            self:pushUndo(contact.undo_entry)
        end
        contact.erased = true
        -- Live feedback. Note: paintTo below is a FULL document repaint into
        -- the framebuffer; only the e-ink refresh is bounded to the bbox. It
        -- runs once per sample that actually removed a stroke, so cost is
        -- bounded by strokes erased, not drag length. The save and a clean
        -- flashing repaint still happen once, on lift.
        local x1, y1 = math.huge, math.huge
        local x2, y2, w = -math.huge, -math.huge, 0
        for _, s in ipairs(removed) do
            if (s.width or 4) > w then w = s.width or 4 end
            for _, p in ipairs(s.points) do
                if p.x < x1 then x1 = p.x end
                if p.y < y1 then y1 = p.y end
                if p.x > x2 then x2 = p.x end
                if p.y > y2 then y2 = p.y end
            end
        end
        if x1 <= x2 and self.ui.view then
            self.ui.view:paintTo(Screen.bb, 0, 0)
            self:refreshRegion(x1, y1, x2, y2, w)
        end
    else
        self:pushUndo({ type = "delete", strokes = removed })
        self:saveStrokes()
        self:renderNow(true)
    end
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
    -- In-progress strokes: one per active drawing contact (usually just one).
    for _, c in pairs(self.contacts) do
        if c.stroke and c.stroke.page == page then
            self:renderStroke(bb, c.stroke)
        end
    end
    if self.enabled then
        self:paintToolbar(bb)
    end
end

function KoWriter:renderStroke(bb, s)
    if not s or not s.points or #s.points < 1 then return end
    local color = self:strokeColor(s)
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
    self:requestRefresh(false)
end

-- --- Undo / clear ------------------------------------------------------------

function KoWriter:undo()
    local a = table.remove(self.undo_stack)
    if not a then return end
    local page
    if a.type == "add" then
        page = a.stroke.page
        -- Remove by identity (indices shift when other strokes are erased).
        for i, s in ipairs(self.strokes) do
            if s == a.stroke then
                table.remove(self.strokes, i)
                break
            end
        end
    elseif a.type == "delete" then
        page = a.strokes[1] and a.strokes[1].page
        for _, s in ipairs(a.strokes) do
            table.insert(self.strokes, s)
        end
    end
    self:rebuildPageIndex()
    self:saveStrokes()
    self:requestRefresh(true)
    -- Undo history spans the whole book; when it touched another page, say so
    -- instead of looking like a no-op. Menu-driven undo only: in write mode a
    -- popup would become a topmost overlay and release the pen to the reader
    -- for its whole lifetime (and strand the toolbar contact).
    if page and page ~= self:getCurrentPage() and not self.enabled then
        UIManager:show(InfoMessage:new{
            text = T(_("Undid ink change on page %1."), page),
            timeout = 2,
        })
    end
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
    self:pushUndo({ type = "delete", strokes = removed })
    self:saveStrokes()
    self:requestRefresh(true)
end

function KoWriter:clearAll()
    self.strokes = {}
    self.page_strokes = {}
    self.undo_stack = {}
    -- An explicit "delete everything" from the user re-arms saving after a
    -- failed load (see loadStrokes/saveStrokes).
    self.load_failed = false
    self:saveStrokes()
    self:requestRefresh(true)
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
    -- Must be a real boolean: menu enabled_func treats nil as "enabled", which
    -- left "Clear this page" tappable on inkless pages (seen on device).
    return indices ~= nil and #indices > 0
end

-- --- Persistence -------------------------------------------------------------

-- Where ink lives: the same sidecar directory family DocSettings:flush uses.
-- doc_sidecar_dir is always "<book>.sdr beside the book", but the user may
-- have moved metadata to koreader/docsettings/ or the hash location; follow
-- that choice so ink sits with the rest of the book's metadata.
function KoWriter:getStrokesFilePath()
    if not (self.ui and self.ui.doc_settings) then return nil end
    local ds = self.ui.doc_settings
    local loc = G_reader_settings
        and G_reader_settings:readSetting("document_metadata_folder") or "doc"
    local dir = ds[loc .. "_sidecar_dir"] or ds.doc_sidecar_dir
    if not dir then return nil end
    return dir .. "/kowriter_strokes.lua"
end

-- Strict shape check before trusting file contents: a malformed stroke (e.g.
-- nil page) would otherwise crash rebuildPageIndex inside init().
local function validateStrokeData(data)
    if type(data) ~= "table" or type(data.strokes) ~= "table" then return false end
    for _, s in ipairs(data.strokes) do
        if type(s) ~= "table" or type(s.page) ~= "number"
                or type(s.points) ~= "table" then
            return false
        end
        for _, p in ipairs(s.points) do
            if type(p) ~= "table" or type(p.x) ~= "number"
                    or type(p.y) ~= "number" then
                return false
            end
        end
    end
    return true
end

-- Show a message now, or queue it if the reader isn't on screen yet: showing
-- from init() would stack the popup BELOW the ReaderUI being constructed, so
-- it would only surface (stale and unexplained) after closing the book.
function KoWriter:notify(text)
    if self._reader_ready then
        UIManager:show(InfoMessage:new{ text = text })
    else
        self._pending_msg = text
    end
end

-- Read one stroke file. Returns "newer" (format from a newer build),
-- a stroke-data table, false (present but unreadable), or nil (absent).
local function readStrokeFile(p)
    local f = io.open(p, "r")
    if not f then return nil end
    f:close()
    local ok, data = pcall(dofile, p)
    if ok and type(data) == "table" and type(data.version) == "number"
            and data.version > STROKES_FORMAT_VERSION then
        return "newer"
    end
    if ok and validateStrokeData(data) then return data end
    return false
end

function KoWriter:loadStrokes()
    local path = self:getStrokesFilePath()
    if not path then return end
    self.strokes = {}
    self.page_strokes = {}
    self._migrate_from = nil

    local primary = readStrokeFile(path)
    if primary == "newer" then
        -- Written by a newer KoWriter: leave the file strictly alone.
        logger.warn("KoWriter: strokes file has a newer format version")
        self.load_failed = true
        self.strokes_loaded = true
        self:notify(_("This book's ink was saved by a newer version of KoWriter and can't be read here. It will not be modified."))
        return
    end
    if type(primary) == "table" then
        self.strokes = primary.strokes
        self:rebuildPageIndex()
        self.load_failed = false
        self.strokes_loaded = true
        logger.info("KoWriter: loaded", #self.strokes, "strokes")
        return
    end
    if primary == false then
        -- Present but unreadable. Set it aside (recoverable), then try the
        -- .old backup kept by the last successful save.
        local ok_b, berr = os.rename(path, path .. ".bad")
        if not ok_b then
            logger.warn("KoWriter: could not set corrupt strokes file aside:", berr)
        end
        local backup = readStrokeFile(path .. ".old")
        if type(backup) == "table" then
            self.strokes = backup.strokes
            self:rebuildPageIndex()
            self.load_failed = false
            self.strokes_loaded = true
            logger.warn("KoWriter: strokes file unreadable; restored",
                #self.strokes, "strokes from backup")
            self:notify(T(_("This book's ink file was unreadable, so KoWriter restored the previous save (your newest strokes may be missing). The unreadable file was kept as:\n%1"),
                path .. ".bad"))
            return
        end
        -- No usable backup: refuse to save until the user explicitly clears —
        -- saving now would replace their ink with the empty set we fell back to.
        self.load_failed = true
        self.strokes_loaded = true
        self:notify(T(_([[KoWriter could not read this book's saved ink.
The unreadable file was kept as:
%1

You can restore that file manually, or use "Clear all ink in this book" to start over. Until then, new ink will not be saved for this book.]]),
            path .. ".bad"))
        return
    end
    -- Nothing at the configured location: fall back to the legacy
    -- beside-the-book sidecar (ink saved before the metadata-folder setting
    -- was honored). It is set aside after the first successful save at the
    -- new location, so a later settings flip can't resurrect a stale copy.
    local legacy = self.ui.doc_settings.doc_sidecar_dir
        and self.ui.doc_settings.doc_sidecar_dir .. "/kowriter_strokes.lua"
    if legacy and legacy ~= path then
        local ldata = readStrokeFile(legacy)
        if type(ldata) == "table" then
            self.strokes = ldata.strokes
            self:rebuildPageIndex()
            self._migrate_from = legacy
            logger.info("KoWriter: loaded", #self.strokes,
                "strokes from legacy sidecar; migrating on next save")
        end
    end
    self.load_failed = false
    self.strokes_loaded = true
end

function KoWriter:warnSaveFailedOnce(err)
    if self._save_warned then return end
    self._save_warned = true
    UIManager:show(InfoMessage:new{
        text = T(_("KoWriter could not save ink:\n%1\n\nYour ink is kept in memory for now but may be lost when the book closes."),
            tostring(err)),
    })
end

function KoWriter:saveStrokes()
    if self._save_cb then
        UIManager:unschedule(self._save_cb)
    end
    self._save_scheduled = false
    local path = self:getStrokesFilePath()
    if not path then return end
    -- Never overwrite a file we could not read (see loadStrokes); clearAll()
    -- re-arms saving as the explicit user decision.
    if self.load_failed then return end
    -- Avoid clobbering an existing file with an empty set before we ever loaded.
    if #self.strokes == 0 and not self.strokes_loaded then return end
    local dir = path:match("(.*)/")
    if dir and not lfs.attributes(dir, "mode") then
        -- The "dir"/"hash" metadata locations are several levels deep; create
        -- the whole chain (lfs.mkdir only makes one level).
        local ok, err = util.makePath(dir)
        if not ok then
            logger.warn("KoWriter: could not create sidecar dir:", err)
        end
    end
    -- Atomic replace (same pattern as DocSettings:flush): write a temp file,
    -- verify every write, keep the previous file as .old, rename into place.
    -- A crash or full disk mid-save can no longer destroy the existing ink.
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "w")
    if not f then
        logger.err("KoWriter: cannot write strokes:", err)
        self:warnSaveFailedOnce(err)
        return
    end
    local ok_w, werr = f:write("return "
        .. dump({ version = STROKES_FORMAT_VERSION, strokes = self.strokes }))
    local ok_c, cerr = f:close()
    if not ok_w or not ok_c then
        logger.err("KoWriter: stroke write failed:", werr or cerr)
        os.remove(tmp)
        self:warnSaveFailedOnce(werr or cerr)
        return
    end
    local had_prev = lfs.attributes(path, "mode") == "file"
    if had_prev then
        os.remove(path .. ".old")
        local ok_o, oerr = os.rename(path, path .. ".old")
        if not ok_o then
            logger.warn("KoWriter: could not keep .old backup:", oerr)
            had_prev = false
        end
    end
    local ok_r, rerr = os.rename(tmp, path)
    if not ok_r then
        logger.err("KoWriter: stroke rename failed:", rerr)
        -- Roll the backup straight back so a readable file stays in place —
        -- otherwise the next load would see "never saved" and a later save
        -- would delete the .old holding the only good copy.
        if had_prev then
            os.rename(path .. ".old", path)
        end
        os.remove(tmp)
        self:warnSaveFailedOnce(rerr)
        return
    end
    -- Ink read from the legacy beside-the-book file is now safely written at
    -- the configured location; set the legacy copy aside so a later settings
    -- flip can't load a stale version over this one.
    if self._migrate_from and self._migrate_from ~= path then
        os.remove(self._migrate_from .. ".migrated")
        local ok_m, merr = os.rename(self._migrate_from,
            self._migrate_from .. ".migrated")
        if ok_m then
            self._migrate_from = nil
        else
            logger.warn("KoWriter: could not set legacy sidecar aside:", merr)
        end
    end
end

-- --- Lifecycle ---------------------------------------------------------------

function KoWriter:onReaderReady()
    self._reader_ready = true
    if not self.strokes_loaded then self:loadStrokes() end
    if self._pending_msg then
        UIManager:show(InfoMessage:new{ text = self._pending_msg })
        self._pending_msg = nil
    end
end

-- Rotation / resize invalidates toolbar geometry (computed from screen width)
-- for both painting and hit-testing.
function KoWriter:onSetRotationMode()
    if self.enabled then
        self:computeToolbar()
        self:requestRefresh(true)
    end
end

function KoWriter:onScreenResize()
    if self.enabled then
        self:computeToolbar()
        self:requestRefresh(true)
    end
end

-- In continuous/scroll view one page number spans many scroll positions, so
-- screen-space ink cannot follow the text. Warn once instead of failing silently.
function KoWriter:isScrollMode()
    if self.ui.paging then
        return self.view.page_scroll == true
    end
    return self.view.view_mode == "scroll"
end

-- Gate enabling on a one-time scroll-view confirmation. A ConfirmBox (not a
-- timed InfoMessage after enabling): a popup shown over live write mode would
-- be a topmost overlay and release the pen to the reader until it timed out.
function KoWriter:confirmScrollMode(proceed)
    if self._scroll_warned then return proceed() end
    local ok, scroll = pcall(function() return self:isScrollMode() end)
    if not ok or not scroll then return proceed() end
    self._scroll_warned = true
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("You are in continuous/scroll view: ink is pinned to the screen position where it was drawn and will not follow the text as it scrolls. Page view works best for ink.\n\nEnable write mode anyway?"),
        ok_text = _("Enable"),
        ok_callback = proceed,
    })
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
    -- A contact interrupted by suspend will never deliver its lift; don't
    -- come back from sleep with the hook still swallowing everything.
    if self._pending_unhook then
        self:removeInputHook()
    end
    self:saveStrokes()
end

-- --- Menu --------------------------------------------------------------------

-- One axis of the calibration submenu: a spinner that nudges ink position.
function KoWriter:offsetSpinItem(label, info, getter, setter)
    return {
        keep_menu_open = true,
        text_func = function() return T("%1: %2 px", label, getter()) end,
        callback = function(touchmenu_instance)
            local SpinWidget = require("ui/widget/spinwidget")
            UIManager:show(SpinWidget:new{
                title_text = label,
                info_text = info,
                value = getter(),
                value_min = -300,
                value_max = 300,
                value_step = 1,
                value_hold_step = 10,
                ok_text = _("Set"),
                callback = function(spin)
                    setter(spin.value)
                    self:saveSettings()
                    -- Repaint so the new mapping takes effect for the next stroke
                    -- and the label updates.
                    if self.enabled then self:requestRefresh(false) end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    }
end

function KoWriter:calibrationMenu()
    return {
        self:offsetSpinItem(_("Horizontal offset"),
            _("Positive moves ink to the right, negative to the left."),
            function() return self.offset_x end,
            function(v) self.offset_x = v end),
        self:offsetSpinItem(_("Vertical offset"),
            _("Positive moves ink down, negative up."),
            function() return self.offset_y end,
            function(v) self.offset_y = v end),
        {
            text = _("Reset to no offset"),
            keep_menu_open = true,
            enabled_func = function()
                return self.offset_x ~= 0 or self.offset_y ~= 0
            end,
            callback = function(touchmenu_instance)
                self.offset_x, self.offset_y = 0, 0
                self:saveSettings()
                if self.enabled then self:requestRefresh(false) end
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
    }
end

function KoWriter:addToMainMenu(menu_items)
    menu_items.kowriter = {
        text = _("KoWriter"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Write mode"),
                help_text = _("When on, the pen/finger draws on the page and normal reading gestures are suspended. Use the on-page toolbar's Done button (or this toggle) to leave.\n\nTip: for one-tap access, map \"KoWriter: toggle write mode\" to a gesture or a hardware key under Settings (gear) -> Taps and gestures -> Gesture manager."),
                checked_func = function() return self.enabled end,
                callback = function()
                    if self.enabled then
                        self:setEnabled(false)
                    else
                        self:confirmScrollMode(function()
                            self:setEnabled(true)
                        end)
                    end
                end,
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
                text = _("Raw coordinates (no rotation fix)"),
                help_text = _("Turn on only if your ink lands in the wrong place. Toggles whether touch coordinates are rotated to match the screen orientation."),
                checked_func = function() return self.raw_coords end,
                callback = function()
                    self.raw_coords = not self.raw_coords
                    self:saveSettings()
                end,
            },
            {
                text_func = function()
                    return T(_("Calibrate ink position (X %1, Y %2)"),
                        self.offset_x, self.offset_y)
                end,
                help_text = _("If ink lands a little off from the pen tip -- the way it doesn't in the built-in notes app, which calibrates the pen -- nudge it here. The offset is in screen pixels for your current reading orientation (+X right, +Y down). Set it, then draw to check."),
                sub_item_table = self:calibrationMenu(),
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
                -- Also enabled after a failed load: the recovery message
                -- points here, and it must be reachable with zero strokes.
                text = _("Clear all ink in this book"),
                enabled_func = function()
                    return #self.strokes > 0 or self.load_failed
                end,
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
    local hooked = self:isHookActive()
    UIManager:show(InfoMessage:new{
        text = T(_([[KoWriter

Write mode: %1
Tool: %2
Color: %3   Width: %4
Input hook active: %5
Ink offset: X %6, Y %7

Current page: %8
Ink on this page: %9
Total strokes in book: %10

Storage: %11]]),
            self.enabled and _("ON") or _("off"),
            self.current_tool,
            COLORS[self.color_index].name,
            WIDTHS[self.width_index],
            hooked and _("yes") or _("no"),
            self.offset_x,
            self.offset_y,
            tostring(page),
            on_page,
            #self.strokes,
            self:getStrokesFilePath() or _("unavailable")),
    })
end

return KoWriter
