# Tesserae for KOReader

A KOReader plugin that turns an e-reader into a [Tesserae](https://tesserae.ink) panel. It works with a self-hosted Tesserae server and with Tesserae Cloud, using the same device protocol every other Tesserae panel speaks.

- **Pairs with a claim code.** No tokens to type. Make a code in Tesserae, enter it once on the reader.
- **16 grey levels.** Frames arrive packed at 4 bits per pixel and are decoded on the reader, so text and photos use the full greyscale of the panel.
- **Colour on colour readers.** A Kobo Libra Colour or Clara Colour gets its frames as colour PNGs and draws them in colour. See [Colour readers](#colour-readers).
- **Sleeps between refreshes.** On Kobo, and on Kindles whose KOReader build exposes the hardware alarm, the reader wakes for each refresh and suspends again. Elsewhere it stays awake on a timer with Wi-Fi off in between.
- **Cheap when nothing changed.** An unchanged dashboard costs one small request and no repaint.
- **TLS verified** against the reader's CA bundle. A switch in the menu turns that off for a self-signed home server.

Supported readers: anything KOReader runs on. Kindles need a jailbreak first; Kobo, PocketBook, reMarkable and the desktop emulator do not. The plugin reports the real screen size when it pairs, so no per-model configuration is needed.

## Install

1. Download `tesserae.koplugin` from the [latest release](https://github.com/dmellok/tesserae-koreader/releases) and unzip it.
2. Copy the `tesserae.koplugin` folder into `koreader/plugins/` on the reader.
3. Restart KOReader.

If KOReader's TRMNL plugin is also installed and set to auto-refresh, disable one of them. Two plugins repainting the same screen fight over it.

## Pair

1. In Tesserae, make a claim code.
   - **Tesserae Cloud:** Settings › Panels › New claim code.
   - **Self-hosted:** Settings › Devices › Add device › Pair with a code.
2. On the reader: **Tools › Tesserae › Pair with a claim code…** Enter the server (the default is `https://cloud.tesserae.ink`; put your own server's address here for self-hosted) and the code.
3. Back in Tesserae the reader appears as a panel. Assign it a dashboard.
4. On the reader: **Tools › Tesserae › Show dashboard**.

Tap the dashboard at any time for Refresh now, Status, and Hide dashboard.

## Settings

All under **Tools › Tesserae**.

| Setting | Default | Notes |
|---|---|---|
| Sleep between refreshes | on | Uses the hardware alarm when KOReader exposes one on this reader. Greyed out when it does not; the reader then stays awake and refreshes by timer. |
| Turn Wi-Fi off between refreshes | on | Saves most of the power on readers that stay awake. |
| Verify TLS certificates | on | Off only for a self-hosted server with a self-signed certificate. |

The refresh interval is set in Tesserae, per panel, and picked up on the next check-in. A lineup step or quiet hours can pull a wake forward or push it back; the reader follows the server's answer.

## Colour readers

On a reader with a colour screen (Kobo Libra Colour, Kobo Clara Colour, both E Ink Kaleido 3, and any other reader KOReader reports as colour) the plugin pairs as a `kaleido3` panel instead of a greyscale one. The server then sends each frame as a 24-bit PNG at the screen's resolution, already reduced to the 16 levels per channel the panel can show, and the plugin draws it in colour with the colour refresh KOReader uses for its own image viewer.

What to expect from Kaleido colour: the colour filter sits over a greyscale panel, so colours are soft and muted compared with a phone or a printed page, roughly 4096 colours at a quarter of the greyscale resolution, and the screen is a little darker with the filter in place. Photos, charts and coloured status tiles read clearly; a dashboard built around large areas of saturated colour will look pastel. Text and lines stay at the full greyscale resolution.

Colour follows KOReader's own switch. With **Screen › Color rendering** off in KOReader the plugin pairs as a greyscale panel and shows greyscale frames, and the Status screen says so.

A colour reader paired with an earlier version of this plugin is registered with the server as a greyscale panel and keeps receiving greyscale frames. Choose **Pair again** once (with a fresh claim code) so the server learns the screen is colour; the Status screen points this out while it applies.

## How it works

Each wake:

1. `GET /api/v1/device/<id>/frame` with `If-None-Match` set to the last frame's id. A 304 means nothing changed and the cycle ends there.
2. Download the frame. A packed frame is decoded into an 8-bit blit buffer; a PNG (what a colour reader gets) is decoded by KOReader's image stack into a colour buffer. Either is painted with a full refresh, the colour one flagged so the Kaleido colour waveform is used.
3. `POST /api/v1/device/<id>/status` with the battery level. The answer carries the interval and, when a lineup or quiet window is near, the exact time to wake.
4. Arm the next wake, drop Wi-Fi, suspend.

The wire format for greyscale is the one Tesserae's ESP32 firmware paints: row major, no header, 1 bit per pixel for mono, 2 for four greys, 4 for sixteen. The plugin infers the depth from the byte count. A frame that starts with the PNG signature is handed to the image decoder whatever the server labelled it.

## Development

```sh
brew install luajit        # or apt-get install luajit
luajit spec/run.lua        # 33 tests, no KOReader needed
```

`protocol.lua`, `frame.lua` and `wake.lua` are dependency free and tested under plain LuaJIT with KOReader's blit buffer stubbed. `main.lua` is the KOReader glue. The KOReader emulator on a desktop is the quickest way to try the whole plugin; the sibling-module loader uses `dofile` on the plugin's own folder, so the folder can be symlinked into the emulator's `plugins/`.

## Licence

AGPL-3.0-or-later. See [LICENSE](LICENSE).
