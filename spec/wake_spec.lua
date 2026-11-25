local Wake = dofile("tesserae.koplugin/wake.lua")
local t = require("spec.support.t")

local function fake_uimanager()
    local ui = { scheduled = {}, suspended = 0, prevent = 0, allow = 0 }
    function ui:scheduleIn(s, cb) self.scheduled[#self.scheduled + 1] = { s = s, cb = cb } end
    function ui:unschedule(cb)
        for i = #self.scheduled, 1, -1 do if self.scheduled[i].cb == cb then table.remove(self.scheduled, i) end end
    end
    function ui:suspend() self.suspended = self.suspended + 1 end
    function ui:preventStandby() self.prevent = self.prevent + 1 end
    function ui:allowStandby() self.allow = self.allow + 1 end
    return ui
end

local function fake_wakeup_mgr()
    local m = { _task_queue = {}, removed = {} }
    function m:addTask(s, cb) table.insert(self._task_queue, { epoch = 1000 + s, callback = cb }) end
    function m:removeTasks(epoch)
        self.removed[#self.removed + 1] = epoch
        for i = #self._task_queue, 1, -1 do if self._task_queue[i].epoch == epoch then table.remove(self._task_queue, i) end end
    end
    return m
end

t.describe("mode", function()
    t.it("uses the hardware alarm only when the device has one and the user wants it", function()
        local ui = fake_uimanager()
        local kobo = { wakeup_mgr = fake_wakeup_mgr(), canSuspend = function() return true end }
        t.eq(Wake.new({ Device = kobo, UIManager = ui }):mode(true), "rtc")
        t.eq(Wake.new({ Device = kobo, UIManager = ui }):mode(false), "awake")
        t.eq(Wake.new({ Device = {}, UIManager = ui }):mode(true), "awake")
    end)
end)

t.describe("schedule", function()
    t.it("arms the alarm and a software timer, and cancel drops both", function()
        local ui = fake_uimanager()
        local dev = { wakeup_mgr = fake_wakeup_mgr(), canSuspend = function() return true end }
        local w = Wake.new({ Device = dev, UIManager = ui })
        local cb = function() end
        t.eq(w:schedule(600, cb, "rtc"), "rtc")
        t.eq(#dev.wakeup_mgr._task_queue, 1)
        t.eq(#ui.scheduled, 1)
        t.eq(w.pending_epoch, 1600)
        w:cancel()
        t.eq(#dev.wakeup_mgr._task_queue, 0)
        t.eq(#ui.scheduled, 0)
        t.eq(dev.wakeup_mgr.removed[1], 1600)
    end)

    t.it("floors very short intervals", function()
        local ui = fake_uimanager()
        local w = Wake.new({ Device = {}, UIManager = ui })
        w:schedule(1, function() end, "awake")
        t.eq(ui.scheduled[1].s, 5)
    end)
end)

t.describe("sleep_now", function()
    t.it("suspends on a Kobo and leaves a Kindle to its power daemon", function()
        local ui = fake_uimanager()
        local kobo = { suspend = function() end, isKindle = function() return false end }
        t.eq(Wake.new({ Device = kobo, UIManager = ui }):sleep_now(), true)
        t.eq(ui.suspended, 1)
        local kindle = { isKindle = function() return true end }
        t.eq(Wake.new({ Device = kindle, UIManager = ui }):sleep_now(), false)
        t.eq(ui.suspended, 1)
    end)

    t.it("holds and releases standby once", function()
        local ui = fake_uimanager()
        local w = Wake.new({ Device = {}, UIManager = ui })
        w:hold_awake()
        w:hold_awake()
        w:release_awake()
        w:release_awake()
        t.eq(ui.prevent, 1)
        t.eq(ui.allow, 1)
    end)
end)

local function fake_kindle()
    local props = {}
    local handle = { set_int_property = function(_, _, name, v) props[#props + 1] = name .. "=" .. v end }
    return { isKindle = function() return true end, powerd = { lipc_handle = handle } }, props
end

t.describe("hold_awake", function()
    t.it("pauses auto suspend and puts it back as it was", function()
        local share = {}
        local w = Wake.new({ Device = { isKindle = function() return false end }, UIManager = fake_uimanager(), PluginShare = share })
        w:hold_awake()
        t.eq(share.pause_auto_suspend, true)
        t.eq(share.keepalive, nil)
        w:release_awake()
        t.eq(share.pause_auto_suspend, nil)
    end)

    t.it("keeps a Kindle's screen saver off for as long as the dashboard is up", function()
        local kindle, props = fake_kindle()
        local share = {}
        local w = Wake.new({ Device = kindle, UIManager = fake_uimanager(), PluginShare = share })
        w:hold_awake()
        t.eq(share.keepalive, true)
        t.eq(props[#props], "preventScreenSaver=1")
        -- the end of a refresh must not let the power daemon suspend
        w:kindle_hold(true)
        w:kindle_hold(false)
        t.eq(props[#props], "preventScreenSaver=1")
        w:release_awake()
        t.eq(props[#props], "preventScreenSaver=0")
        t.eq(share.keepalive, nil)
    end)

    t.it("leaves KOReader's Keep alive on when it was on before", function()
        local kindle, props = fake_kindle()
        local share = { keepalive = true }
        local w = Wake.new({ Device = kindle, UIManager = fake_uimanager(), PluginShare = share })
        -- sleeping between refreshes: a cycle's own hold does not clear Keep alive
        w:kindle_hold(true)
        w:kindle_hold(false)
        t.eq(props[#props], "preventScreenSaver=1")
        w:hold_awake()
        w:release_awake()
        t.eq(share.keepalive, true)
        t.eq(props[#props], "preventScreenSaver=1")
    end)

    t.it("uses the shell when the power daemon's handle is not open", function()
        local ran = {}
        local kindle = { isKindle = function() return true end, powerd = {} }
        local w = Wake.new({ Device = kindle, UIManager = fake_uimanager(), execute = function(c) ran[#ran + 1] = c end })
        w:hold_awake()
        t.eq(ran[1], "lipc-set-prop com.lab126.powerd preventScreenSaver 1")
    end)
end)

t.describe("rtc_missing_reason", function()
    t.it("says nothing when there is a hardware wake, and why when there is not", function()
        local ui = fake_uimanager()
        local kobo = { wakeup_mgr = fake_wakeup_mgr(), canSuspend = function() return true end }
        t.eq(Wake.new({ Device = kobo, UIManager = ui }):rtc_missing_reason(), nil)
        local kindle = { isKindle = function() return true end, supportsScreensaver = function() return true end, powerd = {} }
        local why = Wake.new({ Device = kindle, UIManager = ui }):rtc_missing_reason()
        t.eq(why:find("lipc handle missing", 1, true) ~= nil, true)
    end)
end)
