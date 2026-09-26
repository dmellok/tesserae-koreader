-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (C) 2026 Kayden D'Mello
--
-- The Tesserae device protocol, as a KOReader e-reader speaks it.
--
-- This module is pure Lua with no KOReader dependencies: the HTTP transport
-- and the JSON codec are injected, so the whole request/response layer runs
-- under plain LuaJIT in the test suite. main.lua wires in the real ones.
--
-- Endpoints (identical on a self-hosted server and on Tesserae Cloud):
--
--   POST <base>/api/v1/device/register              X-Pairing-Code: <claim code>
--   GET  <base>/api/v1/device/<id>/frame            If-None-Match: "<render_id>"
--   GET  <frame.url>                                the packed bytes
--   POST <base>/api/v1/device/<id>/status           {battery_pct, fw_version}
--   POST <base>/api/v1/device/<id>/log              free-form lines
--
-- Every authenticated call carries ``Authorization: Bearer <device_token>``.

local Protocol = {}
Protocol.__index = Protocol

Protocol.KIND = "koreader_client"
Protocol.VERSION = "0.1.0"
Protocol.USER_AGENT = "tesserae-koreader/" .. Protocol.VERSION

-- Gamuts the server can pack, finest first, with the width each one needs.
-- 4 bpp needs an even width, 2 bpp a multiple of four, 1 bpp a multiple of eight.
Protocol.GAMUTS = {
    { id = "gray_16", px_per_byte = 2 },
    { id = "gray_4", px_per_byte = 4 },
    { id = "mono", px_per_byte = 8 },
}

local function trim_slash(url)
    return (tostring(url or ""):gsub("/+$", ""))
end

--- Pick the finest gamut whose packing divides the screen width.
-- Returns nil when not even mono fits (a width that is not a multiple of 8).
function Protocol.gamut_for_width(width)
    for _, g in ipairs(Protocol.GAMUTS) do
        if width % g.px_per_byte == 0 then return g.id end
    end
    return nil
end

--- Derive a device id the server accepts: ``[a-zA-Z][a-zA-Z0-9_-]{1,63}``.
-- ``model`` is KOReader's Device.model ("KindlePaperWhite2", "Kobo_clara");
-- ``suffix`` is a per-install random string so two identical readers on one
-- account never collide.
function Protocol.device_id(model, suffix)
    local base = tostring(model or "koreader"):gsub("[^%w_-]", "_")
    if not base:match("^%a") then base = "koreader_" .. base end
    local id = base .. "_" .. tostring(suffix or ""):gsub("[^%w]", "")
    return id:sub(1, 64)
end

--- Create a client.
-- opts.base_url   server origin, e.g. https://cloud.tesserae.ink
-- opts.http       function(req) -> status, body, headers
--                 req = {url, method, headers, body, sink_path}
--                 status 0 means the request never reached a server.
-- opts.json       table with encode(value) and decode(text)
-- opts.device_id, opts.token  identity once paired (may be nil before)
function Protocol.new(opts)
    assert(type(opts) == "table", "opts required")
    assert(type(opts.http) == "function", "opts.http required")
    assert(type(opts.json) == "table", "opts.json required")
    local self = setmetatable({}, Protocol)
    self.base_url = trim_slash(opts.base_url)
    self.http = opts.http
    self.json = opts.json
    self.device_id_value = opts.device_id
    self.token = opts.token
    return self
end

function Protocol:url(path)
    return self.base_url .. "/api/v1/device" .. path
end

function Protocol:auth_headers(extra)
    local h = {
        ["User-Agent"] = Protocol.USER_AGENT,
        ["Accept"] = "application/json",
    }
    if self.token and self.token ~= "" then
        h["Authorization"] = "Bearer " .. self.token
    end
    for k, v in pairs(extra or {}) do h[k] = v end
    return h
end

local function decode_json(json, body)
    if type(body) ~= "string" or body == "" then return nil end
    local ok, value = pcall(json.decode, body)
    if ok and type(value) == "table" then return value end
    return nil
end

--- A uniform failure record.
local function fail(status, message, detail)
    return nil, { status = status or 0, message = message or "request failed", detail = detail }
end

--- Turn an error envelope ({status, error}) or bare status into a message.
local function message_for(status, decoded, body)
    if decoded and type(decoded.error) == "string" then return decoded.error end
    if status == 0 then return type(body) == "string" and body ~= "" and body or "no route to the server" end
    return "HTTP " .. tostring(status)
end

function Protocol:post_json(url, payload, headers)
    local body = self.json.encode(payload or {})
    local h = self:auth_headers(headers)
    h["Content-Type"] = "application/json"
    h["Content-Length"] = tostring(#body)
    return self.http({ url = url, method = "POST", headers = h, body = body })
end

--- Pair this e-reader with a claim code.
-- identity = {device_id, panel_w, panel_h, gamut, model, fw_version}
-- Returns {device_token, device_id, config} or nil, err.
function Protocol:register(code, identity)
    code = tostring(code or ""):gsub("%s", "")
    if code == "" then return fail(400, "a claim code is required") end
    local payload = {
        device_id = identity.device_id,
        kind = Protocol.KIND,
        panel_w = identity.panel_w,
        panel_h = identity.panel_h,
        gamut = identity.gamut,
        fw_version = identity.fw_version or Protocol.VERSION,
        model = identity.model,
        client = "koreader",
    }
    local status, body = self:post_json(self:url("/register"), payload, { ["X-Pairing-Code"] = code })
    local decoded = decode_json(self.json, body)
    -- A self-hosted server answers a fresh pairing with 201 and a re-pair
    -- with 200; Tesserae Cloud always answers 200. Any 2xx with a token is a pair.
    if status < 200 or status > 299 or not decoded or type(decoded.device_token) ~= "string" then
        local msg = message_for(status, decoded, body)
        if status == 403 then msg = "that claim code is not valid or has expired" end
        if status == 409 then msg = decoded and decoded.error or "a panel with this id is already paired; remove it in Tesserae first" end
        if status == 402 then msg = decoded and decoded.error or "the account has reached its panel limit" end
        return fail(status, msg, body)
    end
    self.token = decoded.device_token
    self.device_id_value = decoded.device_id or identity.device_id
    return {
        device_token = decoded.device_token,
        device_id = self.device_id_value,
        config = type(decoded.config) == "table" and decoded.config or {},
    }
end

--- Ask for the current frame.
-- Returns one of:
--   { state = "frame", url, format, panel_w, panel_h, native_w, native_h, render_id, etag }
--   { state = "unchanged", etag }        the etag we sent still matches
--   { state = "empty", reason }          the server has nothing rendered yet
-- or nil, err. err.unpaired is true when the token is no longer accepted.
function Protocol:frame(etag)
    if not self.device_id_value or not self.token then return fail(401, "not paired") end
    local headers = self:auth_headers()
    if etag and etag ~= "" then headers["If-None-Match"] = etag end
    local status, body, resp_headers = self.http({ url = self:url("/" .. self.device_id_value .. "/frame"), method = "GET", headers = headers })
    resp_headers = resp_headers or {}
    if status == 304 then
        return { state = "unchanged", etag = resp_headers.etag or etag }
    elseif status == 204 then
        return { state = "empty", reason = resp_headers["x-tesserae-reason"] or "no frame rendered yet" }
    elseif status == 200 then
        local d = decode_json(self.json, body)
        if not d or type(d.url) ~= "string" then return fail(status, "frame response was not understood", body) end
        return {
            state = "frame",
            url = d.url,
            format = d.format or "bin",
            panel_w = tonumber(d.panel_w),
            panel_h = tonumber(d.panel_h),
            native_w = tonumber(d.native_w) or tonumber(d.panel_w),
            native_h = tonumber(d.native_h) or tonumber(d.panel_h),
            render_id = d.render_id,
            rotation = tonumber(d.rotation),
            etag = resp_headers.etag or (d.render_id and ('"' .. d.render_id .. '"')) or nil,
        }
    end
    local decoded = decode_json(self.json, body)
    local _, err = fail(status, message_for(status, decoded, body), body)
    err.unpaired = (status == 401 or status == 403)
    return nil, err
end

--- Download the frame bytes to a file. Returns true or nil, err.
function Protocol:download(url, sink_path)
    local status, body = self.http({ url = url, method = "GET", headers = self:auth_headers({ ["Accept"] = "*/*" }), sink_path = sink_path })
    if status ~= 200 then return fail(status, "frame download failed: " .. message_for(status, nil, body), body) end
    return true
end

--- Heartbeat. report = {battery_pct, fw_version}
-- Returns { next_poll_s, wake_at, server_time, config } or nil, err.
function Protocol:status(report)
    if not self.device_id_value or not self.token then return fail(401, "not paired") end
    local payload = {
        battery_pct = report and report.battery_pct or nil,
        fw_version = (report and report.fw_version) or Protocol.VERSION,
        client = "koreader",
    }
    local status, body = self:post_json(self:url("/" .. self.device_id_value .. "/status"), payload)
    local decoded = decode_json(self.json, body)
    if status ~= 200 or not decoded then
        local _, err = fail(status, message_for(status, decoded, body), body)
        err.unpaired = (status == 401 or status == 403)
        return nil, err
    end
    return {
        next_poll_s = tonumber(decoded.next_poll_s),
        wake_at = tonumber(decoded.wake_at),
        server_time = tonumber(decoded.server_time),
        config = type(decoded.config) == "table" and decoded.config or {},
    }
end

--- Send log lines. Best effort; the answer is ignored.
function Protocol:log(lines)
    if not self.device_id_value or not self.token then return false end
    local status = self:post_json(self:url("/" .. self.device_id_value .. "/log"), { lines = lines })
    return status == 204 or status == 200
end

--- Seconds until the next wake, from a status answer and the local clock.
-- wake_at is an absolute server epoch that lands before next_poll_s when a
-- lineup step or quiet window is coming; it wins when present and sane.
-- The local clock is not consulted: the answer is computed in the server's
-- clock so a wrong reader clock cannot skew it. `now` stays for callers.
function Protocol.seconds_until_next(status_answer, now, floor_s)
    floor_s = floor_s or 60
    local next_s = tonumber(status_answer and status_answer.next_poll_s) or 900
    local wake_at = tonumber(status_answer and status_answer.wake_at)
    local server_time = tonumber(status_answer and status_answer.server_time)
    if wake_at and server_time then
        -- Work in the server's clock to be immune to a wrong local clock.
        local delta = wake_at - server_time
        if delta > 0 and delta < next_s then next_s = delta end
    end
    if next_s < floor_s then next_s = floor_s end
    return math.floor(next_s)
end

return Protocol
