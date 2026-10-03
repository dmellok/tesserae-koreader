# Changelog

## 0.3.0 (unreleased)

- Colour readers get colour frames. On a reader KOReader reports as having a colour screen (Kobo Libra Colour, Kobo Clara Colour: E Ink Kaleido 3) the plugin pairs as a `kaleido3` panel; the server answers with a 24-bit PNG at the screen's resolution, quantised to the panel's 16 levels per channel, and the plugin draws it in colour. Before this a colour reader paired as a greyscale panel and photos came out grey. The refresh is flagged the way KOReader's image viewer flags its own, which is what makes its e-ink driver use the Kaleido colour waveform for the repaint.
- Colour follows KOReader's Screen › Color rendering switch: with it off the reader pairs as greyscale and the Status screen says why.
- A colour reader paired by an earlier version is still registered as greyscale with the server; the Status screen says so and asks for one Pair again, after which colour frames arrive.
- The Status screen's Screen line shows `kaleido3 (colour)` on a colour reader, and "Last frame: colour" once a colour frame is on screen.
- A frame file that starts with the PNG signature is decoded as an image whatever the server labelled it, so a PNG is never fed to the bit unpacker; a PNG frame sent to a greyscale reader is shown in greyscale as before.
- Greyscale readers are unchanged: the gamut is still picked by which packing divides the screen width, and the packed frame path is untouched.

## 0.2.1 (2026-09-30)

- Showing the dashboard puts the last frame back on screen straight away, from the copy kept on the reader, before Wi-Fi is up. After a KOReader restart, or Hide and then Show, the screen used to stay empty with "Dashboard unchanged" until the dashboard next changed on the server, because the reader still told the server it had that frame. It now only says so while the frame is actually on screen, so a reader with no kept copy gets the frame again.
- A frame is downloaded beside the kept copy and replaces it only once the download succeeds, so a failed download no longer wipes the last good frame.

## 0.2.0 (unreleased)

- A refresh no longer wedges when KOReader never reports Wi-Fi up. KOReader's connectivity check stops after 45 s without calling back, and a connection attempt already in flight never calls back at all; the plugin then stayed "in progress" for good and every later refresh, scheduled or from the menu, returned without doing anything until KOReader was restarted. A 90 s watchdog now ends such a cycle and retries in five minutes; a late Wi-Fi callback starts a fresh cycle instead of being lost.
- The frame request waits up to 75 s instead of 25 s. The server may render the dashboard during that request (a panel with no frame yet, or one whose dashboard just changed), and on Tesserae Cloud a render can queue behind other panels for up to 45 s before it starts.
- A request that runs out of time says "no answer from the server within N s" instead of LuaSocket's bare "timeout".
- Re-pairing from the Tesserae menu keeps the current token and sends it with the claim code. Tesserae Cloud only re-keys an id that is already paired for the holder of its token and otherwise answers 409, so a re-pair used to fail until the panel was removed in the console. Pairing against a different server still starts clean.
- A failed frame download reports the server's reason (for example "frame not found") rather than just the status code.
- When the server answers a poll with "render unavailable: ...", Refresh now shows that reason instead of advising to assign a dashboard.

## 0.1.0 (unreleased)

First version.

- Pairs with a claim code against a self-hosted Tesserae server or Tesserae Cloud.
- Fetches frames through the REST device protocol with `If-None-Match`, decodes 1, 2 and 4 bit packed frames into a greyscale blit buffer, paints with a full refresh.
- Reports battery on every check-in and follows the server's `next_poll_s` and `wake_at`.
- Sleeps between refreshes through KOReader's WakeupMgr where the reader has one; otherwise stays awake on a timer.
- Turns Wi-Fi off between refreshes, verifies TLS against the reader's CA bundle, holds KOReader's sleep screen so the dashboard stays on the panel.
- Tap menu on the dashboard: Refresh now, Status, Hide dashboard.
- Pairing accepts the 201 a self-hosted server answers a fresh pairing with, not only the 200 Tesserae Cloud sends. Before this the reader reported "Pairing failed: HTTP 201" while the server had already created the device.
