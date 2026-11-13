--
-- weather.lua — 同步测试版：确认 IP 直连在 app 进程里能用
--
local fcitx = require("fcitx")

local CACHE_DIR = "/sdcard/Android/data/org.fcitx.fcitx5.android/files/data/.weather"
local WTTR_IP = "5.9.243.187"
local DEBUG_FILE = CACHE_DIR .. "/debug3.log"

local function log(msg)
    local f = io.open(DEBUG_FILE, "a")
    if f then
        f:write(os.date("%H:%M:%S") .. " " .. msg .. "\n")
        f:close()
    end
end

local cache = {}

function weather_query(input)
    if input == nil or #input < 1 then
        return nil
    end

    -- 只有按空格（input 以空格结尾）才触发请求；否则不请求，等待空格
    if input:sub(-1) ~= " " then
        return nil
    end

    local city = input:gsub("[^%w]", "")
    if city == "" or #city > 20 then
        return nil
    end

    -- 有缓存直接返回
    if cache[city] then
        return { cache[city] }
    end

    log("sync request: " .. city)
    local cmd = "curl -s --connect-timeout 2 --max-time 3 " ..
        "-H 'Host: wttr.in' " ..
        "'http://" .. WTTR_IP .. "/" .. city .. "?format=3&lang=zh' 2>&1"
    local h = io.popen(cmd)
    if h then
        local result = h:read("*a")
        h:close()
        log("result: [" .. tostring(result) .. "] len=" .. tostring(#result))
        if result and #result > 2 and not result:match("^curl:") then
            cache[city] = result
            return { result }
        end
    else
        log("io.popen returned nil")
    end

    return nil
end

ime.register_command("wt", "weather_query", "天气", "none", "输入城市拼音如 beijing")
