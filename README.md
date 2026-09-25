# Tesserae for KOReader

A KOReader plugin that turns an e-reader into a [Tesserae](https://tesserae.ink) panel. It works with a self-hosted Tesserae server and with Tesserae Cloud, using the same device protocol every other Tesserae panel speaks.

- **Pairs with a claim code.** No tokens to type. Make a code in Tesserae, enter it once on the reader.
- **16 grey levels.** Frames arrive packed at 4 bits per pixel and are decoded on the reader, so text and photos use the full greyscale of the panel.
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

## How it works

Each wake:

1. `GET /api/v1/device/<id>/frame` with `If-None-Match` set to the last frame's id. A 304 means nothing changed and the cycle ends there.
2. Download the packed frame. Decode it into an 8-bit blit buffer and paint it with a full refresh.
3. `POST /api/v1/device/<id>/status` with the battery level. The answer carries the interval and, when a lineup or quiet window is near, the exact time to wake.
4. Arm the next wake, drop Wi-Fi, suspend.

The wire format is the one Tesserae's ESP32 firmware paints: row major, no header, 1 bit per pixel for mono, 2 for four greys, 4 for sixteen. The plugin infers the depth from the byte count.

## Development

```sh
brew install luajit        # or apt-get install luajit
luajit spec/run.lua        # 22 tests, no KOReader needed
```

`protocol.lua`, `frame.lua` and `wake.lua` are dependency free and tested under plain LuaJIT with KOReader's blit buffer stubbed. `main.lua` is the KOReader glue. The KOReader emulator on a desktop is the quickest way to try the whole plugin; the sibling-module loader uses `dofile` on the plugin's own folder, so the folder can be symlinked into the emulator's `plugins/`.

## Licence

AGPL-3.0-or-later. See [LICENSE](LICENSE).
