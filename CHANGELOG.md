# Changelog

## 0.1.0 (unreleased)

First version.

- Pairs with a claim code against a self-hosted Tesserae server or Tesserae Cloud.
- Fetches frames through the REST device protocol with `If-None-Match`, decodes 1, 2 and 4 bit packed frames into a greyscale blit buffer, paints with a full refresh.
- Reports battery on every check-in and follows the server's `next_poll_s` and `wake_at`.
- Sleeps between refreshes through KOReader's WakeupMgr where the reader has one; otherwise stays awake on a timer.
- Turns Wi-Fi off between refreshes, verifies TLS against the reader's CA bundle, holds KOReader's sleep screen so the dashboard stays on the panel.
- Tap menu on the dashboard: Refresh now, Status, Hide dashboard.
- Pairing accepts the 201 a self-hosted server answers a fresh pairing with, not only the 200 Tesserae Cloud sends. Before this the reader reported "Pairing failed: HTTP 201" while the server had already created the device.
