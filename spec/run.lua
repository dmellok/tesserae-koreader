-- Test runner: `luajit spec/run.lua` from the repository root.
--
-- KOReader's ffi/blitbuffer is not available outside the app, so a minimal
-- 8-bit stand-in with the same fields the decoder touches (data, stride,
-- rotate) is registered before the specs load. Everything else under test
-- is dependency free.
package.path = "./?.lua;" .. package.path

local ffi = require("ffi")

package.preload["ffi/blitbuffer"] = function()
    local BB = {}
    local mt = {}
    mt.__index = mt
    function mt:getPixel8(x, y) return self.data[y * self.stride + x] end
    function mt:rotate(deg) self.rotation = deg end
    function mt:free() end
    function BB.new(w, h, _type)
        local stride = w + (w % 4 ~= 0 and (4 - w % 4) or 0)
        local buf = ffi.new("uint8_t[?]", stride * h)
        return setmetatable({ w = w, h = h, stride = stride, data = buf, rotation = 0 }, mt)
    end
    BB.TYPE_BB8 = 1
    return BB
end

local t = require("spec.support.t")
for _, spec in ipairs({ "spec/protocol_spec.lua", "spec/frame_spec.lua", "spec/wake_spec.lua" }) do
    dofile(spec)
end
os.exit(t.report() and 0 or 1)
