# Changelog

## Unreleased

- Page-turn keys change the dashboard. On a reader with physical keys (a Kindle 4, a Kobo Libra or Sage) the back and forward keys, and Left and Right on a five-way pad, are reported to the server as the `left` and `right` buttons with the next frame request; by default they show the previous and the next dashboard of the panel's lineup, and the new page comes back on the same request. The key's own name goes along as `button_key` (`lpgback`, `lpgfwd`, `rpgback`, `rpgfwd`, `left`, `right`), so the panel's button map in Tesserae can give one key its own action, such as a fixed dashboard. Every other key (Home, Menu, Back) still opens the plugin menu. Needs no server update: both a self-hosted server and Tesserae Cloud already take button presses on this route.
- Touch actions on the dashboard. A tap or a swipe is reported to the server with the next frame request, which runs the action of the touch region under it: change page, step a rotation, fire a webhook, or call a Home Assistant service. A page change comes back on the same request.
- The plugin menu (Refresh now, Status, Hide dashboard) moved from a tap to a long press. Physical keys other than the page-turn keys still open it.
- A touch runs as an interactive refresh, like Refresh now: the reader is not put to sleep right after it, and Wi-Fi follows the Turn Wi-Fi off between refreshes setting. A Home Assistant action, which the server repaints a few seconds after the touch, shows on the next refresh.
- A touch is reported in the pixels of the frame as downloaded, with `touch_space=fb`, so the server maps it onto the dashboard through the rotation it packed the frame with. A dashboard turned against the panel (a landscape dashboard on a reader held in portrait) needs Tesserae 0.510.0 or later; an older server only hits the right control on an unrotated frame.
- A touch is only reported while the frame on screen matches the screen orientation; a frame the plugin had to rotate gets a message instead.
- Frame patches. A greyscale reader advertises overlay schema 2, and a small change to the page on screen (a clock, a few values) arrives as changed rectangles on the frame it holds: the plugin copies them into a copy of the frame kept on disk, which stays as downloaded because every patch is relative to it, and refreshes only those rectangles, without the full-screen flash. The heartbeat now goes before the frame request, because a patch still unfetched at that request counts as undelivered and the server sends the whole frame instead. After eight patches in a row the next one repaints the whole screen. Colour readers do not ask for patches.
- Each completed refresh logs one line with the time each step finished (status, patch, frame, download, paint) and whether a touch, a manual refresh or the timer started it, to tell server time from reader time.

## 0.3.0 (2026-10-04)

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
