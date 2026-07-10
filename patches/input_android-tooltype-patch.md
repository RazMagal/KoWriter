# Optional patch: expose stylus tool‑type on Android (real palm rejection)

**You do not need this to use KoWriter.** Without it, pen and finger both draw.
Apply it only if you want true palm rejection — after which you can enable
**KoWriter → Pen only (ignore finger)** and rest your hand on the screen freely.

This is the same change that would let *any* KOReader stylus plugin work on
Android, and it's the fix that belongs upstream (see koreader/koreader
Discussion #15039). It edits KOReader's bundled input glue, so it's for people
comfortable modifying/rebuilding their KOReader install. It is **version
sensitive**: match it to your KOReader's actual source, don't paste blindly.

## Why it's needed

On Android, KOReader receives touches through `AMotionEvent` and translates them
in `koreader-base/ffi/input_android.lua`. That translator reads only x / y /
pointer‑id / time and **throws away the tool type** — so KOReader literally
cannot tell a stylus from a finger. Android *does* provide it
(`AMotionEvent_getToolType`); it's just never read. This patch reads it and
forwards it as the `ABS_MT_TOOL_TYPE` event KOReader already understands from
Kobo.

## The change — 2 files

### 1. Declare the FFI function

In the launcher's FFI declarations (the `ffi.cdef[[ ... ]]` block that declares
the other `AMotionEvent_*` functions — in `android-luajit-launcher`'s
`android.lua` / `assets/android.lua`), add one line next to
`AMotionEvent_getPressure`:

```c
int32_t AMotionEvent_getToolType(const AInputEvent* motion_event, size_t pointer_index);
```

### 2. Emit the tool type in `input_android.lua`

In `koreader-base/ffi/input_android.lua`, add a small mapping helper and emit an
`ABS_MT_TOOL_TYPE` event from the touch‑down and touch‑move generators.

Add near the top of the file (after the `genEmuEvent` definition):

```lua
-- Android AMOTION_EVENT_TOOL_TYPE_* -> KOReader ABS_MT_TOOL_TYPE convention
-- (0 = finger, 1 = pen, 2 = eraser). STYLUS=2, ERASER=4, FINGER=1 on Android.
local function androidToolType(event, index)
    local ok, t = pcall(function()
        return tonumber(android.lib.AMotionEvent_getToolType(event, index))
    end)
    if not ok or not t then return 0 end
    if t == 2 then return 1        -- STYLUS -> pen
    elseif t == 4 then return 2    -- ERASER -> eraser
    else return 0 end              -- FINGER / MOUSE / UNKNOWN -> finger
end
```

Then, inside `genTouchDownEvent(event, slot, index)` — right after the
`ABS_MT_TRACKING_ID` line — insert:

```lua
    genEmuEvent(C.EV_ABS, C.ABS_MT_TOOL_TYPE, androidToolType(event, index), timev)
```

And inside `genTouchMoveEvent(event, timev, slot, index)` — after the
`ABS_MT_SLOT` line — insert the same emit so the tool type stays current during
a stroke:

```lua
    genEmuEvent(C.EV_ABS, C.ABS_MT_TOOL_TYPE, androidToolType(event, index), timev)
```

`C.ABS_MT_TOOL_TYPE` (value 55) is already available via the `linux_input_h`
FFI include that `input_android.lua` pulls in through the `Input` class, but if
`C.ABS_MT_TOOL_TYPE` is nil in your build, use the literal `55`.

## Result

KOReader's `Input` class already reads `ABS_MT_TOOL_TYPE` into each touch slot's
`.tool` field (`0` finger, `1` pen, `2` eraser). After this patch, KoWriter's
input hook sees `slot.tool` populated, so:

- **KoWriter → Pen only (ignore finger)** actually ignores finger/palm touches.
- A future KoWriter version can auto‑switch to the eraser when you flip a
  stylus that reports the eraser end.

## Verifying

With **Input debug** in KOReader's dev settings, or by watching `adb logcat`,
confirm touches now carry a tool type. In KoWriter, enable *Pen only*, then draw
with a finger (should do nothing) and the stylus (should draw).

## Note on risk

This edits the file that handles **all** touch input on Android. If you get it
wrong, touch may stop working — keep a backup of the original files and know how
to restore them (reinstall the KOReader APK) before you start.
