-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (C) 2026 Kayden D'Mello
--
-- Packed Tesserae frames to greyscale pixels.
--
-- The server packs a frame the way every Tesserae panel receives it: row
-- major, top-left origin, no header, no padding.
--
--   1 bpp   8 px per byte, MSB is the leftmost pixel, bit set = white   (mono)
--   2 bpp   4 px per byte, MSB first, value 0..3 = grey level            (gray_4)
--   4 bpp   2 px per byte, high nibble = even column, value 0..15        (gray_16)
--
-- ``Frame.walk`` is the generic decoder used by the tests; ``Frame.to_blitbuffer``
-- is the fast path that writes straight into a KOReader 8-bit blit buffer via
-- the FFI.

local Frame = {}

-- The eight-byte PNG signature.
local PNG_SIGNATURE = "\137PNG\r\n\26\n"
Frame.PNG_SIGNATURE = PNG_SIGNATURE

--- True when the bytes are a PNG file rather than a packed frame. The server
-- says ``format = "png"`` for a colour reader; the signature check lets the
-- decoder trust the bytes over the label, so a PNG is never fed to the bit
-- unpacker and a packed frame never to the image decoder.
function Frame.is_png(bytes)
    return type(bytes) == "string" and bytes:sub(1, #PNG_SIGNATURE) == PNG_SIGNATURE
end

--- Bits per pixel implied by a byte count, or nil when nothing fits.
function Frame.bpp_for(byte_count, w, h)
    local px = w * h
    if px <= 0 then return nil end
    for _, bpp in ipairs({ 1, 2, 4 }) do
        if byte_count * 8 == px * bpp then return bpp end
    end
    return nil
end

--- Grey value 0..255 for a wire value at a bit depth.
local function grey(bpp, v)
    if bpp == 1 then return v == 1 and 255 or 0 end
    if bpp == 2 then return v * 85 end
    return v * 17
end
Frame.grey = grey

--- Call ``put(x, y, grey)`` for every pixel. Slow, dependency free.
function Frame.walk(bytes, w, h, bpp, put)
    local byte = string.byte
    if bpp == 1 then
        local row_bytes = w / 8
        for y = 0, h - 1 do
            local base = y * row_bytes
            for bx = 0, row_bytes - 1 do
                local b = byte(bytes, base + bx + 1)
                for k = 0, 7 do
                    local bit = math.floor(b / (2 ^ (7 - k))) % 2
                    put(bx * 8 + k, y, bit == 1 and 255 or 0)
                end
            end
        end
    elseif bpp == 2 then
        local row_bytes = w / 4
        for y = 0, h - 1 do
            local base = y * row_bytes
            for bx = 0, row_bytes - 1 do
                local b = byte(bytes, base + bx + 1)
                put(bx * 4, y, grey(2, math.floor(b / 64) % 4))
                put(bx * 4 + 1, y, grey(2, math.floor(b / 16) % 4))
                put(bx * 4 + 2, y, grey(2, math.floor(b / 4) % 4))
                put(bx * 4 + 3, y, grey(2, b % 4))
            end
        end
    else
        local row_bytes = w / 2
        for y = 0, h - 1 do
            local base = y * row_bytes
            for bx = 0, row_bytes - 1 do
                local b = byte(bytes, base + bx + 1)
                put(bx * 2, y, grey(4, math.floor(b / 16)))
                put(bx * 2 + 1, y, grey(4, b % 16))
            end
        end
    end
end

--- Decode into a KOReader BlitBuffer (TYPE_BB8). Requires LuaJIT's ffi and
-- KOReader's ffi/blitbuffer. Returns the buffer or nil, message.
-- ``rotate`` (0/90/180/270) is applied as the buffer's rotation flag so the
-- image lands the way the composition was laid out when the server packed at
-- a transposed stride.
function Frame.to_blitbuffer(bytes, w, h, rotate)
    local bpp = Frame.bpp_for(#bytes, w, h)
    if not bpp then
        return nil, string.format("frame is %d bytes, which is not a 1, 2 or 4 bpp %dx%d buffer", #bytes, w, h)
    end
    local ok_ffi, ffi = pcall(require, "ffi")
    local ok_bb, Blitbuffer = pcall(require, "ffi/blitbuffer")
    if not ok_ffi or not ok_bb then return nil, "no blit buffer available" end

    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    local dst = ffi.cast("uint8_t*", bb.data)
    local stride = tonumber(bb.stride)
    local src = ffi.cast("const uint8_t*", bytes)
    local bor, band, rshift = bit.bor, bit.band, bit.rshift

    if bpp == 4 then
        local row_bytes = w / 2
        for y = 0, h - 1 do
            local s = y * row_bytes
            local d = y * stride
            for bx = 0, row_bytes - 1 do
                local b = src[s + bx]
                dst[d + bx * 2] = rshift(b, 4) * 17
                dst[d + bx * 2 + 1] = band(b, 0x0f) * 17
            end
        end
    elseif bpp == 2 then
        local row_bytes = w / 4
        for y = 0, h - 1 do
            local s = y * row_bytes
            local d = y * stride
            for bx = 0, row_bytes - 1 do
                local b = src[s + bx]
                local x = d + bx * 4
                dst[x] = rshift(b, 6) * 85
                dst[x + 1] = band(rshift(b, 4), 3) * 85
                dst[x + 2] = band(rshift(b, 2), 3) * 85
                dst[x + 3] = band(b, 3) * 85
            end
        end
    else
        local row_bytes = w / 8
        for y = 0, h - 1 do
            local s = y * row_bytes
            local d = y * stride
            for bx = 0, row_bytes - 1 do
                local b = src[s + bx]
                local x = d + bx * 8
                for k = 0, 7 do
                    dst[x + k] = band(rshift(b, 7 - k), 1) == 1 and 255 or 0
                end
            end
        end
    end
    -- bor is referenced so a LuaJIT build without bit.bor fails loudly here, not mid-loop.
    if not bor then return nil, "bit library missing" end
    if rotate and rotate ~= 0 then bb:rotate(rotate) end
    return bb
end

--- Turn to apply so a buffer packed at ``native_w x native_h`` shows as a
-- ``screen_w x screen_h`` composition. 0 when the strides already agree.
function Frame.rotation_for(native_w, native_h, screen_w, screen_h)
    if native_w == screen_w and native_h == screen_h then return 0 end
    if native_w == screen_h and native_h == screen_w then return 90 end
    return 0
end

return Frame
