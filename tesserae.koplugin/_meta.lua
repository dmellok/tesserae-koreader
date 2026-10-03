-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (C) 2026 Kayden D'Mello
local _ = require("gettext")
return {
    name = "tesserae",
    fullname = _("Tesserae"),
    description = _([[Shows a Tesserae dashboard on this e-reader. Pair with a claim code from your Tesserae server or Tesserae Cloud, then the e-reader fetches frames on a schedule and sleeps in between.]]),
    version = "0.3.0",
}
