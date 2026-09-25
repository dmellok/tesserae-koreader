local Frame = dofile("tesserae.koplugin/frame.lua")
local t = require("spec.support.t")

local function collect(bytes, w, h, bpp)
    local px = {}
    Frame.walk(bytes, w, h, bpp, function(x, y, g) px[y * w + x + 1] = g end)
    return px
end

t.describe("bpp_for", function()
    t.it("infers the depth from the byte count", function()
        t.eq(Frame.bpp_for(758 * 1024 / 8, 758, 1024), 1)
        t.eq(Frame.bpp_for(758 * 1024 / 4, 758, 1024), 2)
        t.eq(Frame.bpp_for(758 * 1024 / 2, 758, 1024), 4)
        t.eq(Frame.bpp_for(123, 758, 1024), nil)
    end)
end)

t.describe("walk", function()
    t.it("decodes 1 bpp with the MSB on the left and set bits white", function()
        -- 8x2: row 0 = 10000001, row 1 = 01111110
        local px = collect(string.char(0x81, 0x7e), 8, 2, 1)
        t.eq(px[1], 255)
        t.eq(px[2], 0)
        t.eq(px[8], 255)
        t.eq(px[9], 0)
        t.eq(px[10], 255)
        t.eq(px[16], 0)
    end)

    t.it("decodes 2 bpp, MSB first, four levels", function()
        -- one byte: 00 01 10 11
        local px = collect(string.char(0x1b), 4, 1, 2)
        t.eq(px[1], 0)
        t.eq(px[2], 85)
        t.eq(px[3], 170)
        t.eq(px[4], 255)
    end)

    t.it("decodes 4 bpp with the high nibble on the left", function()
        -- 0xF0 -> white, black ; 0x8A -> 136, 170
        local px = collect(string.char(0xf0, 0x8a), 4, 1, 4)
        t.eq(px[1], 255)
        t.eq(px[2], 0)
        t.eq(px[3], 8 * 17)
        t.eq(px[4], 10 * 17)
    end)
end)

t.describe("to_blitbuffer", function()
    -- The KOReader blit buffer is stubbed in spec/run.lua with a plain
    -- 8-bit row buffer, so the FFI fast path can be checked against walk().
    t.it("matches the reference decoder for every depth", function()
        local w, h = 16, 3
        for _, bpp in ipairs({ 1, 2, 4 }) do
            local n = w * h * bpp / 8
            local bytes = {}
            for i = 1, n do bytes[i] = string.char((i * 37 + bpp) % 256) end
            bytes = table.concat(bytes)
            local ref = collect(bytes, w, h, bpp)
            local bb, err = Frame.to_blitbuffer(bytes, w, h, 0)
            t.eq(err, nil)
            for y = 0, h - 1 do
                for x = 0, w - 1 do
                    t.eq(bb:getPixel8(x, y), ref[y * w + x + 1], string.format("bpp %d at %d,%d", bpp, x, y))
                end
            end
        end
    end)

    t.it("refuses a buffer of the wrong size", function()
        local bb, err = Frame.to_blitbuffer(string.rep("x", 7), 16, 3, 0)
        t.eq(bb, nil)
        t.truthy(err:find("not a 1, 2 or 4 bpp"))
    end)

    t.it("applies the rotation flag when the stride is transposed", function()
        t.eq(Frame.rotation_for(1024, 758, 758, 1024), 90)
        t.eq(Frame.rotation_for(758, 1024, 758, 1024), 0)
        local bb = Frame.to_blitbuffer(string.rep("\0", 16 * 8 / 8), 16, 8, 90)
        t.eq(bb.rotation, 90)
    end)
end)
