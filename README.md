# KoWriter

Write and draw **directly on the document** with your stylus (or finger) in
KOReader — the "ink on the page" experience the Onyx BOOX built‑in notes app
gives you, but inside KOReader, on the book you're actually reading. Your ink is
saved per page and reappears when you come back.

KOReader has **no native stylus support on Android** (Onyx BOOX, Bigme, etc.).
The only ink‑on‑document plugin that exists, `pencil.koplugin`, is Kobo‑only. This
plugin fills that gap for Android e‑readers.

> **Status: v1, working on hardware** (tested on an Onyx BOOX Note3). It is
> designed to be safe: nothing is hooked until you turn *Write mode* on, so if
> something misbehaves, just leave write mode and reading is completely
> unaffected.

---

## What it does

- Freehand pen drawing overlaid on the page (PDF, EPUB, etc.).
- Eraser, undo, clear‑page, clear‑book.
- A few pen colors and widths (on a grayscale panel, colors show as gray shades).
- An on‑page toolbar (Done / Pen‑Erase / Color / Width / Undo / Clear / ‹ ›).
- Ink saved to the book's sidecar folder and restored automatically.

## How it works (one paragraph)

On Android the stylus arrives as an ordinary touch, so KoWriter taps the raw
touch stream by wrapping `Device.input.gesture_detector.feedEvent` — the same
technique `notes.koplugin` uses — to capture every point at full rate *before* it
becomes a tap/swipe. While *Write mode* is on, those touches are consumed so the
reader doesn't turn pages under your pen. It draws by registering as a KOReader
"view module", so its `paintTo` runs on every page repaint and lays your ink over
the page. Strokes are stored per page number in the document's sidecar directory.

---

## Install

> For a step‑by‑step walkthrough (adb and manual, plus updating/uninstalling),
> see **[INSTALL.md](INSTALL.md)**. Short version below.

1. Copy the `kowriter.koplugin` folder into KOReader's `plugins` directory.

   On an Onyx BOOX device, KOReader's home folder is usually
   `/sdcard/koreader/` (or `/mnt/sdcard/koreader/`). So the target is:

   ```
   /sdcard/koreader/plugins/kowriter.koplugin/
   ```

   Via USB with `adb`:
   ```bash
   adb push kowriter.koplugin /sdcard/koreader/plugins/
   ```

   Or just drag the folder over MTP/USB into `koreader/plugins/`.

2. Restart KOReader (fully close and reopen, or use the menu's *Exit* /
   *Restart*).

3. Open a book. You should see **☰ → More tools → KoWriter**.

## Use

1. Open the menu → **More tools → KoWriter → Write mode** (or map a gesture to
   *KoWriter: toggle write mode* under **Gear → Taps and gestures → Gesture
   manager**, which is far more convenient).
2. The toolbar appears at the top. Write anywhere on the page with the stylus.
3. Tap toolbar buttons:
   - **Done** — leave write mode (reading gestures come back).
   - **Pen / Erase** — toggle the tool.
   - **Black / Red / …** — cycle pen color.
   - **W2 / W4 / …** — cycle pen width.
   - **Undo**, **Clear** (this page), **‹** / **›** (previous/next page).
4. Leave write mode with **Done**. Your ink stays visible while you read and is
   saved with the book.

---

## Tuning & troubleshooting

**Ink lands a little off from the pen tip.** The built-in notes app calibrates
the pen to the panel; KOReader can't, so on some devices ink sits a few pixels
away from where you touch. Open **KoWriter → Calibrate ink position** and nudge
the horizontal/vertical offset until ink lands under the pen. The offset is in
screen pixels for your current reading orientation (+X right, +Y down) and is
remembered. Set it, then draw to check.

**Ink is badly mirrored or rotated (not just a small offset).** This depends on
how your specific panel reports touch coordinates. KoWriter now rotates touch
input exactly the way KOReader's own gesture engine does (via the screen's
touch-rotation), so this should be right out of the box — but if it isn't, open
**KoWriter → Raw coordinates (no rotation fix)** and toggle it; one of the two
settings will be correct for your device and orientation.

**My palm draws too.** On stock Android, KOReader can't tell the pen from a
finger, so both draw (there is no reliable way to separate them, so KoWriter
doesn't pretend to — each touch just draws its own stroke). Two options:

- Rest your palm off the screen while writing (simplest), or
- Apply the optional tool‑type patch (see `patches/`). Once the device reports
  tool types, KoWriter **automatically** ignores finger/palm touches and only the
  pen draws — no setting to flip.

**Nothing draws / it turns pages instead.** Make sure *Write mode* is **on**
(check **KoWriter → About / status** — it shows "Write mode: ON" and "Input hook
active: yes"). If the hook isn't active, toggle write mode off and on again.

**Ink drifts after changing font size (EPUB).** Strokes are stored by page
number in screen coordinates, so re‑flowing the text (font size, margins,
line spacing) moves the words out from under old ink. Do your annotating at a
settled font size. Fixed‑layout PDFs don't have this problem. (This is the same
limitation `pencil.koplugin` has; a future version could anchor ink to text
positions.)

**Where is my ink stored?** In the book's sidecar folder, as
`kowriter_strokes.lua` (see the exact path in **About / status**). Delete that
file to wipe all ink for a book.

## Diagnosing on device

KoWriter logs to KOReader's log. To watch it:

```bash
adb logcat | grep -i kowriter
```

or read `koreader/crash.log`. The lines `KoWriter: input hook installed` and
`KoWriter: loaded N strokes` confirm the two moving parts are working.

---

## Limitations (v1, honest list)

- **No palm rejection** without the optional patch (each touch draws its own
  stroke, so a stray palm/phantom touch makes its own mark but won't corrupt the
  line you're writing).
- **No pressure / tilt** (stock Android drops it before KOReader sees it).
- **Ink is screen‑space per page**, so font/zoom/rotation changes can misalign
  existing EPUB ink.
- **Continuous/scroll view is not supported for ink**: one page number spans
  many scroll positions, so ink stays pinned to the screen position where it was
  drawn and does not follow the text. When you enable write mode from the menu
  in scroll view, KoWriter asks once before enabling; use page view for
  annotating.
- **Latency** is KOReader's normal e‑ink refresh, not Onyx's proprietary fast
  pen layer — smooth, but not as instant as the native notes app.
- While write mode is on, **all** touch gestures are suspended (by design); use
  the toolbar or the Done button / a mapped hardware‑key gesture to get out.

## Roadmap

- Optional core patch merged upstream so pen/finger separation works out of the
  box (see `patches/input_android-tooltype-patch.md`).
- Anchor EPUB ink to text positions (xpointer) so it survives re‑flow.
- Smoothed strokes and a proper floating tool palette.

## Credits

Input‑hook approach adapted from `notes.koplugin` (prasy‑loyola); overlay
rendering and per‑page persistence patterns adapted from `pencil.koplugin`
(mysticknits). Both are GPLv3, like KOReader.
