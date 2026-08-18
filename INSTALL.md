# HowTo — Install KoWriter

A step‑by‑step guide to getting KoWriter running on an Android e‑reader
(Onyx BOOX, Bigme, etc.). Tested on an Onyx **Note3**.

## Prerequisites

- **KOReader** already installed on the device (from the KOReader releases /
  F‑Droid / the device's app store). Launch it once so its `koreader/` folder
  exists.
- A way to copy files to the device — either:
  - **`adb`** over USB (recommended; used below), or
  - plain **USB/MTP** file transfer (drag‑and‑drop).

Find KOReader's home folder on the device — usually `/sdcard/koreader/`
(same as `/storage/emulated/0/koreader/`). Plugins live in its `plugins/`
subfolder.

---

## Install with adb (recommended)

From the folder containing `kowriter.koplugin/`:

```bash
# 1. Confirm the device is connected
adb devices          # should list your device as "device"

# 2. Copy the plugin into KOReader's plugins folder
adb push kowriter.koplugin /sdcard/koreader/plugins/

# 3. Restart KOReader so it loads the new plugin
adb shell am force-stop org.koreader.launcher
adb shell monkey -p org.koreader.launcher -c android.intent.category.LAUNCHER 1
```

## Install manually (USB / MTP)

1. Connect the device by USB and allow file transfer.
2. Copy the whole `kowriter.koplugin` folder into
   `…/koreader/plugins/` on the device.
3. Fully close and reopen KOReader.

---

## Confirm it loaded

1. Open any book.
2. Tap the top of the screen → **☰ menu → More tools → KoWriter**.
   If you see the KoWriter submenu, it's installed.

(If it's missing: check the folder is exactly
`koreader/plugins/kowriter.koplugin/` containing `main.lua` and `_meta.lua`,
and that you restarted KOReader. You can also watch the load log with
`adb logcat | grep -i kowriter` — you should see `KoWriter: initialized`.)

## Use it (30‑second version)

1. **More tools → KoWriter → Write mode** (or map *KoWriter: toggle write mode*
   to a gesture under **Gear → Taps and gestures** — much handier).
2. Write on the page with the stylus. Use the top toolbar:
   **Done · Pen/Erase · Color · Width · Undo · Clear · ‹ ›**.
3. Tap **Done** to go back to reading. Your ink stays and is saved with the book.

See `README.md` for full details, tuning (e.g. the *Raw coordinates* toggle if
ink is offset), and limitations.

---

## Update the plugin later

Push the changed file(s) and restart KOReader:

```bash
adb push kowriter.koplugin/main.lua /sdcard/koreader/plugins/kowriter.koplugin/
adb shell am force-stop org.koreader.launcher
adb shell monkey -p org.koreader.launcher -c android.intent.category.LAUNCHER 1
```

## Uninstall

Delete the folder and restart KOReader:

```bash
adb shell rm -rf /sdcard/koreader/plugins/kowriter.koplugin
```

Your saved ink is **not** removed by uninstalling — it lives in each book's
sidecar folder as `kowriter_strokes.lua`. Remove that file (per book) to delete
the ink too.

---

## Optional: real palm rejection

By default both finger and stylus draw, because stock Android doesn't tell
KOReader which is which. To make the pen draw while your palm is ignored, apply
the small core patch in `patches/input_android-tooltype-patch.md`. Once the
device reports tool types, KoWriter ignores finger/palm touches **automatically**
— there is no setting to flip. It's optional and advanced (it edits KOReader's
bundled input code) — the plugin works fine without it.
