-- The smallest test helper that reads well: describe / it / eq / truthy.
local t = { passed = 0, failed = 0, failures = {} }
local current = ""

function t.describe(name, fn)
    local prev = current
    current = prev ~= "" and (prev .. " › " .. name) or name
    fn()
    current = prev
end

function t.it(name, fn)
    local ok, err = pcall(fn)
    if ok then
        t.passed = t.passed + 1
    else
        t.failed = t.failed + 1
        t.failures[#t.failures + 1] = current .. " › " .. name .. "\n    " .. tostring(err)
    end
end

local function show(v)
    if type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end

function t.eq(actual, expected, label)
    if actual ~= expected then
        error((label and (label .. ": ") or "") .. "expected " .. show(expected) .. ", got " .. show(actual), 2)
    end
end

function t.truthy(v, label)
    if not v then error((label and (label .. ": ") or "") .. "expected a truthy value", 2) end
end

function t.report()
    for _, f in ipairs(t.failures) do io.stderr:write("FAIL " .. f .. "\n") end
    io.stdout:write(string.format("%d passed, %d failed\n", t.passed, t.failed))
    return t.failed == 0
end

return t
