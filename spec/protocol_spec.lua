-- Protocol tests: run with `luajit spec/run.lua`.
local Protocol = dofile("tesserae.koplugin/protocol.lua")
local json = dofile("spec/support/json.lua")
local t = require("spec.support.t")

-- A scripted HTTP transport: each call pops the next canned answer and
-- records the request for assertions.
local function transport(answers)
    local calls = {}
    return function(req)
        calls[#calls + 1] = req
        local a = table.remove(answers, 1)
        assert(a, "unexpected request " .. req.method .. " " .. req.url)
        return a.status, a.body or "", a.headers or {}
    end, calls
end

t.describe("device_id", function()
    t.it("sanitises the model and keeps the id server-legal", function()
        t.eq(Protocol.device_id("KindlePaperWhite2", "a1b2c3"), "KindlePaperWhite2_a1b2c3")
        t.eq(Protocol.device_id("Kobo_clara", "zz"), "Kobo_clara_zz")
        t.eq(Protocol.device_id("7 inch (odd)", "x"), "koreader_7_inch__odd__x")
        t.truthy(Protocol.device_id(nil, "abc"):match("^[a-zA-Z][a-zA-Z0-9_-]+$"))
    end)
end)

t.describe("gamut_for_width", function()
    t.it("prefers 16 greys, then 4, then mono", function()
        t.eq(Protocol.gamut_for_width(758), "gray_16")
        t.eq(Protocol.gamut_for_width(1072), "gray_16")
        t.eq(Protocol.gamut_for_width(1236), "gray_16")
        t.eq(Protocol.gamut_for_width(602), "gray_16")
        t.eq(Protocol.gamut_for_width(601), nil)
    end)
end)

t.describe("register", function()
    t.it("sends the claim code and the panel, and keeps the token", function()
        local http, calls = transport({
            { status = 200, body = json.encode({ status = 200, device_token = "tsk_abc", device_id = "KindlePaperWhite2_a1b2c3", config = { sleep_interval_s = 900 } }) },
        })
        local p = Protocol.new({ base_url = "https://cloud.tesserae.ink/", http = http, json = json })
        local r, err = p:register(" 1234 5678 ", { device_id = "KindlePaperWhite2_a1b2c3", panel_w = 758, panel_h = 1024, gamut = "gray_16", model = "KindlePaperWhite2" })
        t.eq(err, nil)
        t.eq(r.device_token, "tsk_abc")
        t.eq(r.config.sleep_interval_s, 900)
        t.eq(#calls, 1)
        t.eq(calls[1].url, "https://cloud.tesserae.ink/api/v1/device/register")
        t.eq(calls[1].method, "POST")
        t.eq(calls[1].headers["X-Pairing-Code"], "12345678")
        t.eq(calls[1].headers["Authorization"], nil)
        local body = json.decode(calls[1].body)
        t.eq(body.kind, "koreader_client")
        t.eq(body.panel_w, 758)
        t.eq(body.gamut, "gray_16")
        t.eq(p.token, "tsk_abc")
    end)

    t.it("accepts the 201 a self-hosted server answers a fresh pairing with", function()
        local http = transport({
            { status = 201, body = json.encode({ status = 201, device_token = "tsk_self", device_id = "kobo_spabw_d2d8f7", config = { sleep_interval_s = 900 }, reused_existing = false }) },
        })
        local p = Protocol.new({ base_url = "http://192.168.0.10:5000", http = http, json = json })
        local r, err = p:register("12345678", { device_id = "kobo_spabw_d2d8f7", panel_w = 1072, panel_h = 1448, gamut = "gray_16", model = "Kobo_spaBW" })
        t.eq(err, nil)
        t.eq(r.device_token, "tsk_self")
        t.eq(p.token, "tsk_self")
    end)

    t.it("carries the token it already holds, so a re-pair re-keys the same id", function()
        local http, calls = transport({
            { status = 200, body = json.encode({ status = 200, device_token = "tsk_new", device_id = "KindlePaperWhite2_a1b2c3", config = {} }) },
        })
        local p = Protocol.new({ base_url = "https://cloud.tesserae.ink", http = http, json = json, device_id = "KindlePaperWhite2_a1b2c3", token = "tsk_old" })
        local r, err = p:register("12345678", { device_id = "KindlePaperWhite2_a1b2c3", panel_w = 758, panel_h = 1024, gamut = "gray_16" })
        t.eq(err, nil)
        t.eq(calls[1].headers["Authorization"], "Bearer tsk_old")
        t.eq(calls[1].headers["X-Pairing-Code"], "12345678")
        t.eq(r.device_token, "tsk_new")
        t.eq(p.token, "tsk_new")
    end)

    t.it("explains a bad code, a taken id, and a full plan", function()
        local http = transport({
            { status = 403, body = json.encode({ status = 403, error = "invalid or expired pairing code" }) },
            { status = 409, body = json.encode({ status = 409, error = "a panel is already paired as X; remove it in the console first, then pair this one" }) },
            { status = 402, body = json.encode({ status = 402, error = "plan allows 1 device" }) },
            { status = 0, body = "host not found" },
        })
        local p = Protocol.new({ base_url = "http://h", http = http, json = json })
        local id = { device_id = "X", panel_w = 8, panel_h = 8, gamut = "mono" }
        local _, e1 = p:register("1", id)
        t.truthy(e1.message:find("not valid"))
        local _, e2 = p:register("1", id)
        t.truthy(e2.message:find("already paired"))
        local _, e3 = p:register("1", id)
        t.eq(e3.message, "plan allows 1 device")
        local _, e4 = p:register("1", id)
        t.eq(e4.status, 0)
        t.eq(e4.message, "host not found")
        local _, e5 = p:register("", id)
        t.eq(e5.status, 400)
    end)
end)

t.describe("frame", function()
    local function paired(answers)
        local http, calls = transport(answers)
        return Protocol.new({ base_url = "http://h", http = http, json = json, device_id = "dev1", token = "tok" }), calls
    end

    t.it("returns the envelope and remembers the etag", function()
        local p, calls = paired({
            { status = 200, headers = { etag = '"abc"' }, body = json.encode({ url = "http://h/blob/abc?sig=1", format = "bin", panel_w = 758, panel_h = 1024, native_w = 758, native_h = 1024, render_id = "abc", button_wake_s = 0 }) },
        })
        local f = p:frame(nil)
        t.eq(f.state, "frame")
        t.eq(f.etag, '"abc"')
        t.eq(f.native_w, 758)
        t.eq(calls[1].headers["Authorization"], "Bearer tok")
        t.eq(calls[1].headers["If-None-Match"], nil)
        t.eq(calls[1].url, "http://h/api/v1/device/dev1/frame")
        -- The server may render during this call; the transport gives it longer.
        t.eq(calls[1].slow, true)
    end)

    t.it("download reports the server's own reason on failure", function()
        local p, calls = paired({
            { status = 404, body = json.encode({ status = 404, error = "frame not found" }) },
            { status = 0, body = "no answer from the server within 90 s" },
        })
        local ok, err = p:download("http://h/blob/abc", "/tmp/x.bin")
        t.eq(ok, nil)
        t.eq(err.status, 404)
        t.eq(err.message, "frame download failed: frame not found")
        t.eq(calls[1].slow, nil)
        local _, err2 = p:download("http://h/blob/abc", "/tmp/x.bin")
        t.eq(err2.message, "frame download failed: no answer from the server within 90 s")
    end)

    t.it("maps 304 and 204", function()
        local p, calls = paired({
            { status = 304, headers = { etag = '"abc"' } },
            { status = 204, headers = { ["x-tesserae-reason"] = "no frame rendered yet for this device" } },
        })
        t.eq(p:frame('"abc"').state, "unchanged")
        t.eq(calls[1].headers["If-None-Match"], '"abc"')
        local e = p:frame('"abc"')
        t.eq(e.state, "empty")
        t.truthy(e.reason:find("no frame"))
    end)

    t.it("flags a refused token as unpaired", function()
        local p = paired({ { status = 401, body = json.encode({ status = 401, error = "unknown device token" }) } })
        local f, err = p:frame(nil)
        t.eq(f, nil)
        t.eq(err.unpaired, true)
        t.eq(err.message, "unknown device token")
    end)

    t.it("refuses to run before pairing", function()
        local p = Protocol.new({ base_url = "http://h", http = function() error("no") end, json = json })
        local f, err = p:frame(nil)
        t.eq(f, nil)
        t.eq(err.status, 401)
    end)
end)

t.describe("status and next wake", function()
    t.it("posts battery and reads the poll interval", function()
        local http, calls = transport({
            { status = 200, body = json.encode({ status = 200, config = { sleep_interval_s = 600 }, next_poll_s = 600, server_time = 1000 }) },
        })
        local p = Protocol.new({ base_url = "http://h", http = http, json = json, device_id = "d", token = "t" })
        local s = p:status({ battery_pct = 72 })
        t.eq(s.next_poll_s, 600)
        t.eq(json.decode(calls[1].body).battery_pct, 72)
        t.eq(calls[1].url, "http://h/api/v1/device/d/status")
    end)

    t.it("wake_at pulls the next refresh forward, floors apply", function()
        t.eq(Protocol.seconds_until_next({ next_poll_s = 900, server_time = 1000, wake_at = 1300 }, 0, 60), 300)
        t.eq(Protocol.seconds_until_next({ next_poll_s = 900, server_time = 1000, wake_at = 5000 }, 0, 60), 900)
        t.eq(Protocol.seconds_until_next({ next_poll_s = 10 }, 0, 60), 60)
        t.eq(Protocol.seconds_until_next(nil, 0, 60), 900)
    end)
end)
