-- A small JSON codec for the test suite. KOReader ships its own "json"
-- module on the device; the plugin only needs encode/decode of flat and
-- nested tables, strings, numbers, booleans and null.
local M = {}

local function encode_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
        return map[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n == #t
end

function M.encode(v)
    local t = type(v)
    if v == nil then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v == math.floor(v) then return string.format("%d", v) end
        return string.format("%.14g", v)
    end
    if t == "string" then return encode_string(v) end
    if t == "table" then
        local parts = {}
        if is_array(v) and #v > 0 then
            for _, item in ipairs(v) do parts[#parts + 1] = M.encode(item) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do parts[#parts + 1] = encode_string(k) .. ":" .. M.encode(v[k]) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("cannot encode " .. t)
end

local function skip(s, i)
    return s:match("^%s*()", i)
end

local decode_value

local function decode_string(s, i)
    local out = {}
    i = i + 1
    while true do
        local c = s:sub(i, i)
        if c == "" then error("unterminated string") end
        if c == '"' then return table.concat(out), i + 1 end
        if c == "\\" then
            local n = s:sub(i + 1, i + 1)
            local map = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
            if n == "u" then
                out[#out + 1] = string.char(tonumber(s:sub(i + 2, i + 5), 16) % 256)
                i = i + 6
            else
                out[#out + 1] = map[n] or n
                i = i + 2
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
end

decode_value = function(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local obj = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            local k
            k, i = decode_string(s, skip(s, i))
            i = skip(s, i)
            assert(s:sub(i, i) == ":", "expected colon")
            local v
            v, i = decode_value(s, i + 1)
            obj[k] = v
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "}" then return obj, i + 1 end
            assert(d == ",", "expected comma")
            i = i + 1
        end
    elseif c == "[" then
        local arr = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            local v
            v, i = decode_value(s, i)
            arr[#arr + 1] = v
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "]" then return arr, i + 1 end
            assert(d == ",", "expected comma")
            i = i + 1
        end
    elseif c == '"' then
        return decode_string(s, i)
    elseif s:sub(i, i + 3) == "true" then
        return true, i + 4
    elseif s:sub(i, i + 4) == "false" then
        return false, i + 5
    elseif s:sub(i, i + 3) == "null" then
        return nil, i + 4
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
        assert(num and num ~= "", "unexpected character at " .. i)
        return tonumber(num), i + #num
    end
end

function M.decode(s)
    local v = decode_value(s, 1)
    return v
end

return M
