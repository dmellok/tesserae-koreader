-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (C) 2026 Kayden D'Mello
--
-- Tesserae for KOReader.
--
-- Turns a jailbroken Kindle, a Kobo, or any other e-reader running KOReader
-- into a Tesserae panel. Pair once with a claim code from a self-hosted
-- Tesserae server or from Tesserae Cloud; from then on the reader fetches its
-- frame on the interval the server sets, paints it, reports its battery, and
-- sleeps until the next one.
--
-- Files:
--   protocol.lua  the REST device protocol (pure Lua, tested)
--   frame.lua     packed frame -> blit buffer (pure Lua + ffi, tested)
--   wake.lua      hardware wake vs software timer, suspend handling
--   main.lua      this file: KOReader glue, menu, settings, the refresh cycle

local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

-- Sibling modules live next to this file; KOReader's package.path does not
-- include the plugin folder, so resolve them by hand.
local plugin_dir = (debug.getinfo(1, "S").source:match("^@(.+)$") or ""):match("(.*/)") or "./"
local Protocol = dofile(plugin_dir .. "protocol.lua")
local Frame = dofile(plugin_dir .. "frame.lua")
local Wake = dofile(plugin_dir .. "wake.lua")

local DEFAULT_SERVER = "https://cloud.tesserae.ink"
local HTTP_TIMEOUT_S = 25
-- A frame request can sit behind the server's render gate (45 s on Tesserae
-- Cloud) and then the render itself; 25 s cut those off as "timeout".
local FRAME_TIMEOUT_S = 75
local IMAGE_TIMEOUT_S = 90
local MIN_INTERVAL_S = 60
local RETRY_S = 300
-- How long to wait for KOReader to report Wi-Fi up before giving the cycle
-- up. KOReader's own connectivity check stops after 45 s without calling us
-- back, and a busy network manager never calls back at all.
local WIFI_WAIT_S = 90

-- Candidate CA bundles: KOReader ships one under its data directory on every
-- platform; the others are common system paths for the emulator.
local CA_BUNDLE_CANDIDATES = {
    function() return DataStorage:getDataDir() .. "/ca-bundle.crt" end,
    function() return "./data/ca-bundle.crt" end,
    function() return "/etc/ssl/certs/ca-certificates.crt" end,
    function() return "/etc/ssl/cert.pem" end,
}

local function trim_url(url)
    return (tostring(url or ""):gsub("/+$", ""))
end

local Tesserae = WidgetContainer:extend{
    name = "tesserae",
    is_doc_only = false,
}

-- ---------------------------------------------------------------------------
-- Settings

function Tesserae:loadSettings()
    self.settings_file = LuaSettings:open(DataStorage:getSettingsDir() .. "/tesserae.lua")
    local s = self.settings_file.data or {}
    self.settings = s
    if s.server_url == nil then s.server_url = DEFAULT_SERVER end
    if s.enabled == nil then s.enabled = false end
    if s.sleep_between == nil then s.sleep_between = true end
    if s.wifi_off_between == nil then s.wifi_off_between = true end
    if s.tls_verify == nil then s.tls_verify = true end
    if s.interval_s == nil then s.interval_s = 900 end
    if not s.install_suffix then
        math.randomseed(os.time() + math.floor((os.clock() * 1000) % 1000))
        s.install_suffix = string.format("%06x", math.random(0, 0xffffff))
    end
end

function Tesserae:saveSettings()
    if not self.settings_file then return end
    for k, v in pairs(self.settings) do self.settings_file:saveSetting(k, v) end
    self.settings_file:flush()
end

function Tesserae:isPaired()
    return type(self.settings.device_id) == "string" and type(self.settings.device_token) == "string" and self.settings.device_token ~= ""
end

-- ---------------------------------------------------------------------------
-- Lifecycle

function Tesserae:init()
    self:loadSettings()
    self.wake = Wake.new({ Device = Device, UIManager = UIManager, logger = logger })
    self.in_cycle = false
    self.last_error = nil
    self.last_ok_at = self.settings.last_ok_at
    self.ca_bundle = self:findCaBundle()
    self.refresh_task = function() self:refresh(false) end
    if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end
    if self.settings.enabled and self:isPaired() then
        -- A restart while the dashboard was on: take over the screen shortly
        -- after KOReader is up, on the reader's idle path.
        UIManager:scheduleIn(3, function() self:start(false) end)
    end
end

function Tesserae:onCloseWidget()
    self.wake:cancel()
    self.wake:release_awake()
    self:closeDashboard()
end

--- KOReader is about to suspend. In awake mode our timer would stall; we let
-- it and catch up on resume. In rtc mode the alarm is already armed.
function Tesserae:onSuspend()
    self.suspended_at = os.time()
end

function Tesserae:onResume()
    if not (self.settings.enabled and self:isPaired()) then return end
    -- A user woke the reader (or the alarm did, on a device where KOReader
    -- does not run our task itself). If the refresh is overdue, run it.
    local due = self.next_due_at
    if due and os.time() >= due - 5 and not self.in_cycle then
        UIManager:scheduleIn(2, self.refresh_task)
    end
end

-- ---------------------------------------------------------------------------
-- Transport

function Tesserae:findCaBundle()
    for _, f in ipairs(CA_BUNDLE_CANDIDATES) do
        local ok, path = pcall(f)
        if ok and path and lfs.attributes(path, "mode") == "file" then return path end
    end
    return nil
end

--- The HTTP function Protocol expects: req -> status, body, headers.
-- TLS is verified against the CA bundle when one is found and the user has
-- not switched verification off; otherwise the request is still made, and
-- the status screen says so.
function Tesserae:httpRequest(req)
    local http = require("socket.http")
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local sink_table = {}
    local file
    local sink
    if req.sink_path then
        file = io.open(req.sink_path, "wb")
        if not file then return 0, "cannot write " .. tostring(req.sink_path), {} end
        sink = ltn12.sink.file(file)
    else
        sink = ltn12.sink.table(sink_table)
    end
    local is_https = req.url:match("^https://") ~= nil
    local timeout = (req.sink_path and IMAGE_TIMEOUT_S) or (req.slow and FRAME_TIMEOUT_S) or HTTP_TIMEOUT_S
    http.TIMEOUT = timeout
    https.TIMEOUT = timeout
    local request = {
        url = req.url,
        method = req.method or "GET",
        headers = req.headers or {},
        sink = sink,
        source = req.body and ltn12.source.string(req.body) or nil,
    }
    if is_https then
        request.protocol = "any"
        request.options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" }
        if self.settings.tls_verify and self.ca_bundle then
            request.verify = "peer"
            request.cafile = self.ca_bundle
            self.tls_verified = true
        else
            request.verify = "none"
            self.tls_verified = false
        end
    end
    local client = is_https and https or http
    local ok, status, headers = client.request(request)
    if req.sink_path then
        -- ltn12.sink.file closes the handle on nil; make sure of it either way.
        pcall(function() file:close() end)
    end
    if not ok then
        if req.sink_path then os.remove(req.sink_path) end
        local reason = tostring(status or "network request failed")
        -- LuaSocket's whole explanation is the word "timeout"; say what timed out.
        if reason == "timeout" or reason == "wantread" then
            reason = T(_("no answer from the server within %1 s"), timeout)
        end
        return 0, reason, {}
    end
    local lowered = {}
    for k, v in pairs(headers or {}) do lowered[string.lower(k)] = v end
    return tonumber(status) or 0, table.concat(sink_table), lowered
end

function Tesserae:client()
    return Protocol.new({
        base_url = self.settings.server_url,
        http = function(req) return self:httpRequest(req) end,
        json = require("json"),
        device_id = self.settings.device_id,
        token = self.settings.device_token,
    })
end

-- ---------------------------------------------------------------------------
-- Pairing

function Tesserae:identity()
    local w, h = Screen:getWidth(), Screen:getHeight()
    return {
        device_id = self.settings.device_id or Protocol.device_id(Device.model, self.settings.install_suffix),
        panel_w = w,
        panel_h = h,
        gamut = Protocol.gamut_for_width(w),
        model = tostring(Device.model or "koreader"),
        fw_version = Protocol.VERSION,
    }
end

function Tesserae:showPairDialog()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Pair with Tesserae"),
        fields = {
            {
                description = _("Server"),
                text = self.settings.server_url or DEFAULT_SERVER,
                hint = DEFAULT_SERVER,
            },
            {
                description = _("Claim code (Settings › Panels › New claim code)"),
                text = "",
                hint = _("12345678"),
                input_type = "number",
            },
        },
        buttons = {
            {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                {
                    text = _("Pair"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local server = util.trim(fields[1] or "")
                        local code = util.trim(tostring(fields[2] or ""))
                        if server == "" then server = DEFAULT_SERVER end
                        if not server:match("^https?://") then server = "https://" .. server end
                        if code == "" then
                            UIManager:show(InfoMessage:new{ text = _("Enter the claim code shown in Tesserae.") })
                            return
                        end
                        UIManager:close(dialog)
                        self:pair(server, code)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Tesserae:pair(server, code)
    local identity = self:identity()
    if not identity.gamut then
        UIManager:show(InfoMessage:new{ text = T(_("This screen is %1 pixels wide, which Tesserae cannot pack. Rotate the screen and try again."), identity.panel_w) })
        return
    end
    -- The token is kept until the new one arrives: Tesserae Cloud lets a
    -- reader re-key its own id only when the request carries the current
    -- token, and a failed attempt should leave the pairing that works.
    local same_server = trim_url(server) == trim_url(self.settings.server_url)
    self.settings.server_url = server
    if not same_server then self.settings.device_token = nil end
    self:saveSettings()
    NetworkMgr:runWhenOnline(function()
        local busy = InfoMessage:new{ text = _("Pairing…") }
        UIManager:show(busy)
        UIManager:forceRePaint()
        local client = self:client()
        local result, err = client:register(code, identity)
        UIManager:close(busy)
        if not result then
            self.last_error = err.message
            UIManager:show(InfoMessage:new{ text = T(_("Pairing failed: %1"), err.message), timeout = 8 })
            return
        end
        self.settings.device_id = result.device_id
        self.settings.device_token = result.device_token
        self.settings.paired_at = os.time()
        if type(result.config.sleep_interval_s) == "number" then
            self.settings.interval_s = math.max(MIN_INTERVAL_S, result.config.sleep_interval_s)
        end
        self.last_error = nil
        self:saveSettings()
        UIManager:show(InfoMessage:new{
            text = T(_("Paired as %1.\n\nAssign it a dashboard in Tesserae, then choose Show dashboard."), result.device_id),
            timeout = 8,
        })
    end)
end

function Tesserae:unpair()
    self:stop()
    self.settings.device_id = nil
    self.settings.device_token = nil
    self.settings.etag = nil
    self.settings.paired_at = nil
    self:saveSettings()
    UIManager:show(InfoMessage:new{ text = _("Unpaired. Remove the panel in Tesserae too if you will not pair it again."), timeout = 6 })
end

-- ---------------------------------------------------------------------------
-- Start / stop

--- Take over the screen and begin the refresh cycle.
function Tesserae:start(interactive)
    if not self:isPaired() then
        if interactive then self:showPairDialog() end
        return
    end
    self.settings.enabled = true
    self:saveSettings()
    self:holdSleepScreen()
    if self.wake:mode(self.settings.sleep_between) == "awake" then self.wake:hold_awake() end
    self:refresh(interactive)
end

function Tesserae:stop()
    self.settings.enabled = false
    self:saveSettings()
    self.wake:cancel()
    self.wake:release_awake()
    self.next_due_at = nil
    self:releaseSleepScreen()
    self:closeDashboard()
end

--- KOReader paints its own sleep screen over ours when the reader suspends.
-- "disable" keeps whatever is on the panel. The user's own choice is
-- remembered and put back when the dashboard is switched off.
function Tesserae:holdSleepScreen()
    if self.settings.sleep_screen_held then return end
    self.settings.saved_screensaver_type = G_reader_settings:readSetting("screensaver_type")
    self.settings.sleep_screen_held = true
    G_reader_settings:saveSetting("screensaver_type", "disable")
    self:saveSettings()
end

function Tesserae:releaseSleepScreen()
    if not self.settings.sleep_screen_held then return end
    if self.settings.saved_screensaver_type ~= nil then
        G_reader_settings:saveSetting("screensaver_type", self.settings.saved_screensaver_type)
    else
        G_reader_settings:delSetting("screensaver_type")
    end
    self.settings.sleep_screen_held = nil
    self.settings.saved_screensaver_type = nil
    self:saveSettings()
end

-- ---------------------------------------------------------------------------
-- The refresh cycle

function Tesserae:batteryPct()
    local ok, powerd = pcall(Device.getPowerDevice, Device)
    if ok and powerd and powerd.getCapacity then
        local ok2, pct = pcall(powerd.getCapacity, powerd)
        if ok2 and type(pct) == "number" then return pct end
    end
    return nil
end

function Tesserae:note(msg, timeout)
    if not msg then return end
    UIManager:show(InfoMessage:new{ text = msg, timeout = timeout or 4 })
end

--- One refresh: bring Wi-Fi up, run the cycle, then schedule the next.
function Tesserae:refresh(interactive)
    if self.in_cycle then
        logger.info("Tesserae: refresh already in progress")
        return
    end
    if not (self.settings.enabled and self:isPaired()) then return end
    self.in_cycle = true
    self.wake:cancel()
    self.wake:kindle_hold(true)
    local started = os.time()
    self.cycle_gen = (self.cycle_gen or 0) + 1
    local gen = self.cycle_gen
    local watchdog
    local function run()
        UIManager:unschedule(watchdog)
        if gen ~= self.cycle_gen then
            -- Wi-Fi came up after the watchdog gave this cycle up. Nothing is
            -- running now, so use the connection rather than waste it.
            if not self.in_cycle then self:refresh(interactive) end
            return
        end
        local ok, err = pcall(function() self:cycle(interactive) end)
        if not ok then
            logger.err("Tesserae: cycle failed:", err)
            self.last_error = tostring(err)
            self:finishCycle(RETRY_S, interactive)
        end
    end
    -- KOReader calls back once Wi-Fi is up. It does not call back when its
    -- connectivity check gives up, nor when another connection attempt is
    -- already in flight, and this cycle would then stay "in progress" for
    -- good and every later refresh would return at the top. The watchdog
    -- ends the cycle instead and retries later.
    watchdog = function()
        if gen ~= self.cycle_gen or not self.in_cycle then return end
        logger.warn("Tesserae: Wi-Fi did not come up within", WIFI_WAIT_S, "s")
        self.last_error = _("Wi-Fi did not connect")
        if interactive then self:note(T(_("Tesserae: %1"), self.last_error), 6) end
        self:finishCycle(RETRY_S, interactive)
    end
    UIManager:scheduleIn(WIFI_WAIT_S, watchdog)
    -- turnOnWifiAndWaitForConnection returns false when it could not even
    -- start; then the callback never comes and we must reschedule ourselves.
    local status = NetworkMgr:turnOnWifiAndWaitForConnection(function()
        logger.dbg("Tesserae: Wi-Fi ready after", os.time() - started, "s")
        run()
    end)
    if status == false then
        UIManager:unschedule(watchdog)
        self.last_error = _("Wi-Fi could not be turned on")
        self:finishCycle(RETRY_S, interactive)
    end
end

--- With Wi-Fi up: frame, paint, status, schedule.
function Tesserae:cycle(interactive)
    local client = self:client()
    local frame, err = client:frame(self.settings.etag)
    if not frame then
        self.last_error = err.message
        if err.unpaired then
            logger.warn("Tesserae: token refused (", err.status, "); the panel was removed or re-paired")
            self.settings.device_token = nil
            self:saveSettings()
            self:stop()
            self:note(_("Tesserae no longer knows this e-reader. Pair it again from the Tesserae menu."), 10)
            self.in_cycle = false
            self.wake:kindle_hold(false)
            return
        end
        if interactive then self:note(T(_("Tesserae: %1"), err.message), 6) end
        self:finishCycle(RETRY_S, interactive)
        return
    end

    if frame.state == "frame" then
        local path = DataStorage:getDataDir() .. "/tesserae-frame." .. (frame.format == "png" and "png" or "bin")
        local ok_dl, dl_err = client:download(frame.url, path)
        if not ok_dl then
            self.last_error = dl_err.message
            if interactive then self:note(T(_("Tesserae: %1"), dl_err.message), 6) end
            self:finishCycle(RETRY_S, interactive)
            return
        end
        local painted, paint_err = self:paintFile(path, frame)
        if painted then
            self.settings.etag = frame.etag
            self.last_error = nil
        else
            self.last_error = paint_err
            if interactive then self:note(T(_("Tesserae: %1"), paint_err), 6) end
        end
    elseif frame.state == "unchanged" then
        self.last_error = nil
        if interactive then self:note(_("Dashboard unchanged."), 2) end
        -- The frame is still on the panel from last time. If KOReader has since
        -- painted something else over it (a menu, its own UI) and we hold no
        -- widget, ask for the pixels again next time.
        if not self.dashboard then self.settings.etag = nil end
    elseif frame.state == "empty" then
        self.last_error = frame.reason
        if interactive then
            -- The server says why when its renderer could not take the job;
            -- that is not "assign a dashboard" advice.
            if tostring(frame.reason or ""):find("^render unavailable") then
                self:note(T(_("Tesserae: %1"), frame.reason), 6)
            else
                self:note(_("Nothing to show yet. Assign this panel a dashboard in Tesserae."), 6)
            end
        end
    end

    local report = client:status({ battery_pct = self:batteryPct(), fw_version = Protocol.VERSION })
    local next_s
    if report then
        if type(report.config.sleep_interval_s) == "number" then
            self.settings.interval_s = math.max(MIN_INTERVAL_S, report.config.sleep_interval_s)
        end
        next_s = Protocol.seconds_until_next(report, os.time(), MIN_INTERVAL_S)
        self.last_ok_at = os.time()
        self.settings.last_ok_at = self.last_ok_at
    else
        next_s = math.max(MIN_INTERVAL_S, self.settings.interval_s or RETRY_S)
    end
    self:saveSettings()
    self:finishCycle(next_s, interactive)
end

--- Schedule the next wake, drop Wi-Fi if asked, sleep if allowed.
function Tesserae:finishCycle(next_s, interactive)
    self.in_cycle = false
    self.cycle_gen = (self.cycle_gen or 0) + 1
    self.wake:kindle_hold(false)
    if not self.settings.enabled then return end
    local mode = self.wake:mode(self.settings.sleep_between)
    self.next_due_at = os.time() + next_s
    self.wake:schedule(next_s, self.refresh_task, mode)
    if self.settings.wifi_off_between and Device:hasWifiToggle() then
        NetworkMgr:turnOffWifi(function()
            if mode == "rtc" and not interactive then self.wake:sleep_now() end
        end)
    elseif mode == "rtc" and not interactive then
        self.wake:sleep_now()
    end
end

-- ---------------------------------------------------------------------------
-- Painting

--- Decode a downloaded frame and show it full screen.
function Tesserae:paintFile(path, frame)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local bb
    if frame.format == "png" then
        bb = RenderImage:renderImageFile(path, false, sw, sh)
        if not bb then return false, _("the PNG could not be decoded") end
    else
        local f = io.open(path, "rb")
        if not f then return false, _("the frame file could not be read") end
        local bytes = f:read("*a")
        f:close()
        local nw, nh = frame.native_w or sw, frame.native_h or sh
        local rotate = Frame.rotation_for(nw, nh, sw, sh)
        local err
        bb, err = Frame.to_blitbuffer(bytes, nw, nh, rotate)
        if not bb then return false, err end
    end
    self:showDashboard(bb, sw, sh)
    return true
end

function Tesserae:showDashboard(bb, sw, sh)
    local image = ImageWidget:new{
        image = bb,
        image_disposable = true,
        width = sw,
        height = sh,
        scale_factor = 0,
    }
    local previous = self.dashboard
    local plugin = self
    self.dashboard = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        image,
    }
    self.dashboard.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } } },
    }
    self.dashboard.onTap = function() plugin:onDashboardTap() return true end
    -- Physical keys on Kindles with keypads: any press opens the same menu.
    self.dashboard.onKeyPress = function() plugin:onDashboardTap() return true end
    UIManager:show(self.dashboard)
    -- A full refresh clears ghosting from whatever the reader showed before.
    UIManager:setDirty(self.dashboard, "full")
    if previous then UIManager:close(previous) end
end

function Tesserae:closeDashboard()
    if self.dashboard then
        UIManager:close(self.dashboard)
        self.dashboard = nil
        UIManager:setDirty("all", "full")
    end
end

function Tesserae:onDashboardTap()
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            {
                { text = _("Refresh now"), callback = function() UIManager:close(dialog) self:refresh(true) end },
                { text = _("Status"), callback = function() UIManager:close(dialog) self:showStatus() end },
            },
            {
                { text = _("Hide dashboard"), callback = function() UIManager:close(dialog) self:stop() end },
                { text = _("Back"), callback = function() UIManager:close(dialog) end },
            },
        },
    }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- Status

function Tesserae:describeMode()
    local mode = self.wake:mode(self.settings.sleep_between)
    if mode == "rtc" then return _("sleeps between refreshes (hardware wake)") end
    if self.settings.sleep_between and not self.wake:rtc_available() then
        return _("stays awake (this reader has no hardware wake in KOReader)")
    end
    return _("stays awake, refresh by timer")
end

function Tesserae:showStatus()
    local lines = {}
    if self:isPaired() then
        table.insert(lines, T(_("Paired as %1"), self.settings.device_id))
        table.insert(lines, T(_("Server: %1"), BD.url(self.settings.server_url)))
    else
        table.insert(lines, _("Not paired"))
    end
    table.insert(lines, T(_("Screen: %1×%2, %3"), Screen:getWidth(), Screen:getHeight(), Protocol.gamut_for_width(Screen:getWidth()) or "?"))
    table.insert(lines, T(_("Interval: %1 min"), math.floor((self.settings.interval_s or 900) / 60)))
    table.insert(lines, self:describeMode())
    if self.last_ok_at then table.insert(lines, T(_("Last check-in: %1"), os.date("%Y-%m-%d %H:%M", self.last_ok_at))) end
    if self.next_due_at then table.insert(lines, T(_("Next refresh: %1"), os.date("%H:%M", self.next_due_at))) end
    if self.last_error then table.insert(lines, T(_("Last problem: %1"), self.last_error)) end
    if self.ca_bundle then
        table.insert(lines, self.settings.tls_verify and _("TLS: certificates verified") or _("TLS: verification switched off"))
    else
        table.insert(lines, _("TLS: no certificate bundle found on this reader, connections are not verified"))
    end
    table.insert(lines, T(_("Plugin %1"), Protocol.VERSION))
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

-- ---------------------------------------------------------------------------
-- Menu

function Tesserae:addToMainMenu(menu_items)
    menu_items.tesserae = {
        text = _("Tesserae"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    return self.settings.enabled and _("Hide dashboard") or _("Show dashboard")
                end,
                enabled_func = function() return self:isPaired() end,
                callback = function()
                    if self.settings.enabled then self:stop() else self:start(true) end
                end,
            },
            {
                text = _("Refresh now"),
                enabled_func = function() return self:isPaired() and self.settings.enabled end,
                callback = function() self:refresh(true) end,
            },
            {
                text_func = function()
                    return self:isPaired() and T(_("Pair again (now %1)"), self.settings.device_id) or _("Pair with a claim code…")
                end,
                keep_menu_open = false,
                callback = function() self:showPairDialog() end,
            },
            {
                text = _("Sleep between refreshes"),
                help_text = _("Use the reader's hardware alarm to wake for each refresh and sleep in between. Best for battery. When KOReader has no hardware wake on this reader, it stays awake instead."),
                checked_func = function() return self.settings.sleep_between end,
                enabled_func = function() return self.wake:rtc_available() end,
                callback = function()
                    self.settings.sleep_between = not self.settings.sleep_between
                    self:saveSettings()
                    if self.settings.enabled then self:start(false) end
                end,
                separator = false,
            },
            {
                text = _("Turn Wi-Fi off between refreshes"),
                checked_func = function() return self.settings.wifi_off_between end,
                enabled_func = function() return Device:hasWifiToggle() end,
                callback = function()
                    self.settings.wifi_off_between = not self.settings.wifi_off_between
                    self:saveSettings()
                end,
            },
            {
                text = _("Verify TLS certificates"),
                help_text = _("Check the server's certificate against the reader's CA bundle. Switch off only for a self-hosted server with a self-signed certificate."),
                checked_func = function() return self.settings.tls_verify end,
                enabled_func = function() return self.ca_bundle ~= nil end,
                callback = function()
                    self.settings.tls_verify = not self.settings.tls_verify
                    self:saveSettings()
                end,
                separator = true,
            },
            {
                text = _("Status"),
                keep_menu_open = true,
                callback = function() self:showStatus() end,
            },
            {
                text = _("Unpair"),
                enabled_func = function() return self:isPaired() end,
                callback = function() self:unpair() end,
            },
        },
    }
end

return Tesserae
