-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (C) 2026 Kayden D'Mello
--
-- When to wake, and how to sleep, on this e-reader.
--
-- Two strategies, picked at runtime:
--
--   "rtc"    The device has KOReader's WakeupMgr (Kobo, and Kindles on a
--            KOReader build with lipc wake support). A hardware alarm wakes
--            the reader, KOReader runs our task from its resume path, and the
--            reader goes back to sleep afterwards. Wi-Fi is off in between.
--
--   "awake"  Everything else. The reader is kept from suspending and a
--            UIManager timer fires the refresh. Wi-Fi can still be switched
--            off between refreshes to save most of the power.
--
-- The KOReader objects are injected so the scheduling logic is testable.

local Wake = {}
Wake.__index = Wake

--- deps = { Device, UIManager, logger }
function Wake.new(deps)
    local self = setmetatable({}, Wake)
    self.Device = deps.Device
    self.UIManager = deps.UIManager
    self.logger = deps.logger or { info = function() end, warn = function() end, dbg = function() end }
    self.pending_epoch = nil
    self.pending_cb = nil
    self.standby_held = false
    return self
end

--- Whether a hardware wake is available on this device at all.
function Wake:rtc_available()
    local d = self.Device
    return d ~= nil and d.wakeup_mgr ~= nil and (d.canSuspend == nil or d:canSuspend())
end

--- The strategy in force given the user's preference.
function Wake:mode(prefer_sleep)
    if prefer_sleep and self:rtc_available() then return "rtc" end
    return "awake"
end

--- Drop whatever is scheduled.
function Wake:cancel()
    if self.pending_cb then
        pcall(self.UIManager.unschedule, self.UIManager, self.pending_cb)
    end
    if self.pending_epoch and self:rtc_available() then
        pcall(self.Device.wakeup_mgr.removeTasks, self.Device.wakeup_mgr, self.pending_epoch)
    end
    self.pending_epoch = nil
    self.pending_cb = nil
end

--- Schedule ``cb`` to run in ``seconds`` under ``mode``.
-- Returns the mode actually used.
function Wake:schedule(seconds, cb, mode)
    self:cancel()
    seconds = math.max(5, math.floor(seconds or 900))
    self.pending_cb = cb
    if mode == "rtc" then
        -- KOReader's WakeupMgr keys tasks by the epoch it computes; remember
        -- it so cancel() can remove exactly this one.
        local before = {}
        for _, t in ipairs(self.Device.wakeup_mgr._task_queue or {}) do before[t.epoch] = true end
        self.Device.wakeup_mgr:addTask(seconds, cb)
        for _, t in ipairs(self.Device.wakeup_mgr._task_queue or {}) do
            if not before[t.epoch] and t.callback == cb then self.pending_epoch = t.epoch end
        end
        -- A software timer as well: if the reader is still awake when the
        -- moment comes (the user is using it), refresh anyway. WakeupMgr only
        -- fires through a suspend/resume cycle.
        self.UIManager:scheduleIn(seconds, cb)
        self.logger.info("Tesserae: next refresh in", seconds, "s (hardware wake armed)")
        return "rtc"
    end
    self.UIManager:scheduleIn(seconds, cb)
    self.logger.info("Tesserae: next refresh in", seconds, "s (software timer)")
    return "awake"
end

--- Keep the reader from suspending while we are in charge of the screen.
function Wake:hold_awake()
    if self.standby_held then return end
    self.standby_held = true
    pcall(self.UIManager.preventStandby, self.UIManager)
end

function Wake:release_awake()
    if not self.standby_held then return end
    self.standby_held = false
    pcall(self.UIManager.allowStandby, self.UIManager)
end

--- Put the reader to sleep after a refresh cycle, when the strategy is rtc.
--
-- Kobo: KOReader re-suspends 30 s after a scheduled wake on its own; we
-- cancel that and suspend now, so the reader is not awake longer than the
-- fetch took.
--
-- Kindle: the stock power daemon owns suspend. After an alarm wake it sits in
-- its screen-saver state and suspends again by itself; toggling the power
-- state from here would wake it instead. So nothing is done on a Kindle.
function Wake:sleep_now()
    local d = self.Device
    if d.isKindle and d:isKindle() then
        self.logger.dbg("Tesserae: leaving suspend to the Kindle power daemon")
        return false
    end
    if d.suspend then pcall(self.UIManager.unschedule, self.UIManager, d.suspend) end
    if self.UIManager.suspend then
        self.logger.info("Tesserae: suspending")
        self.UIManager:suspend()
        return true
    end
    return false
end

--- On Kindle, ask the power daemon not to suspend while a cycle runs.
-- Best effort through the powerd's lipc handle; silently a no-op elsewhere.
function Wake:kindle_hold(on)
    local d = self.Device
    if not (d.isKindle and d:isKindle()) then return end
    local powerd = d.powerd
    local handle = powerd and powerd.lipc_handle
    if not handle then return end
    pcall(handle.set_int_property, handle, "com.lab126.powerd", "preventScreenSaver", on and 1 or 0)
end

return Wake
