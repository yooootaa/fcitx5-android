--
-- tools.lua — 翻译（中↔英）+ 汇率换算
-- 触发方式：v + 前缀 + 参数 + 空格（尾随空格才执行，见 weather.lua 同款判据）
-- 联网依赖：app 已有 INTERNET 权限；io.popen 调设备 /system/bin/curl（原生，绕过 cleartext 限制）
--
local fcitx = require("fcitx")

local CACHE_DIR = "/sdcard/Android/data/org.fcitx.fcitx5.android/files/data/.weather"
local DEBUG_FILE = CACHE_DIR .. "/debug_tools.log"

local function log(msg)
    local f = io.open(DEBUG_FILE, "a")
    if f then
        f:write(os.date("%H:%M:%S") .. " " .. msg .. "\n")
        f:close()
    end
end

-- 从 JSON 提取 "key":"..." 的字符串值（处理 \uXXXX 转义）
local function extract_str(json, key)
    local needle = '"' .. key .. '":"'
    local start = string.find(json, needle, 1, true)
    if not start then return nil end
    local i = start + #needle
    local out = {}
    while i <= #json do
        local c = json:sub(i, i)
        if c == "\\" then
            out[#out + 1] = c .. (json:sub(i + 1, i + 1) or "")
            i = i + 2
        elseif c == '"' then
            break
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

-- 从 JSON 提取 "key":<number> 的数字值
local function extract_num(json, key)
    local needle = '"' .. key .. '":'
    local start = string.find(json, needle, 1, true)
    if not start then return nil end
    local i = start + #needle
    local num = {}
    while i <= #json do
        local c = json:sub(i, i)
        if c:match("[%d%.%-%+eE]") then
            num[#num + 1] = c
            i = i + 1
        else
            break
        end
    end
    if #num == 0 then return nil end
    return tonumber(table.concat(num))
end

-- 解码 \uXXXX 转义序列为 UTF-8（Lua 5.4 utf8.char）
local function decode_unicode(s)
    if not s then return nil end
    return (s:gsub("\\u(%x%x%x%x)", function(h)
        local cp = tonumber(h, 16)
        -- 跳过代理对（Lua utf8.char 不接受 0xD800-0xDFFF）
        if cp >= 0xD800 and cp <= 0xDFFF then
            return "\\u" .. h
        end
        return utf8.char(cp)
    end))
end

-- 判断字符串是否含非 ASCII（即含中文）
local function has_non_ascii(s)
    return s:find("[^\1-\127]") ~= nil
end

-- 执行 curl 并返回 stdout（同步，阻塞最多 timeout 秒）
local function curl_get(url, data_enc, timeout)
    local cmd = "curl -s --connect-timeout 2 --max-time " .. tostring(timeout or 6) .. " "
    if data_enc then
        cmd = cmd .. "-G " .. data_enc .. " "
    end
    cmd = cmd .. "'" .. url .. "' 2>&1"
    local h = io.popen(cmd)
    if not h then return nil end
    local result = h:read("*a")
    h:close()
    return result
end

-- ==================== 翻译 ====================
-- 用法：v fy <文本> + 空格
-- 自动检测：含中文 -> 中→英；否则 -> 英→中
-- 必须是全局函数：ime.register_command 用名字字符串注册，fcitx.call_by_name 到全局环境查找
function translate(input)
    if input == nil or #input < 1 then return nil end
    if input:sub(-1) ~= " " then return nil end
    local text = input:sub(1, -2)  -- 去掉尾随空格
    -- 空参数：回退到剪贴板内容（fcitx.clipboard() 读最近一次复制的文本）
    if #text < 1 then
        text = fcitx.clipboard()
        if text == nil or #text < 1 then
            log("translate: empty input and empty clipboard")
            return nil
        end
        log("translate from clipboard: [" .. text .. "]")
    end
    -- 限制长度
    if #text > 100 then return nil end
    local is_zh = has_non_ascii(text)
    local langpair
    if is_zh then
        langpair = "zh-CN|en"
    else
        langpair = "en|zh-CN"
    end
    log("translate [" .. text .. "] dir=" .. langpair)
    local q = "q=" .. text
    local data_enc = "--data-urlencode '" .. q .. "' --data-urlencode 'langpair=" .. langpair .. "'"
    local json = curl_get("https://api.mymemory.translated.net/get", data_enc, 8)
    if not json then
        log("translate: curl nil")
        return nil
    end
    if json:find("^curl:") or json:find("403") or json:find("429") then
        log("translate: error " .. json:sub(1, 60))
        return nil
    end
    local tr = decode_unicode(extract_str(json, "translatedText"))
    if not tr or #tr < 1 then
        log("translate: no result")
        return nil
    end
    log("translate result: [" .. tr .. "]")
    return { tr }
end

-- ==================== 汇率 ====================
-- 用法：v hl <表达式> + 空格
local CURRENCIES = {
    USD = "$", EUR = "€", CNY = "¥", JPY = "¥", GBP = "£",
    KRW = "₩", HKD = "HK$", TWD = "NT$", RUB = "₽", INR = "₹",
    AUD = "A$", CAD = "C$", CHF = "Fr", SGD = "S$", THB = "฿",
    MYR = "RM", VND = "₫", IDR = "Rp", PHP = "₱", BRL = "R$",
    MXN = "MX$", SEK = "kr", NOK = "kr", DKK = "kr", NZD = "NZ$",
}

local function parse_expr(input)
    -- 返回 amount, from, to（to 默认 CNY）
    -- 表达式结构：[金额][from][to]，金额可空，to 可空（默认 CNY）
    -- 例：usd / 100usd / usdcny / 100usdcny / 12.5eurcny
    local s = input:gsub("%s+", ""):upper()
    local amount_s, from, to
    -- 先试 有to： [金额][from][to]
    amount_s, from, to = s:match("^(%d*%.?%d*)(%u%u%u)(%u%u%u)$")
    if not from then
        -- 再试 无to： [金额][from]
        amount_s, from = s:match("^(%d*%.?%d*)(%u%u%u)$")
    end
    if not from then return nil end
    if not CURRENCIES[from] then return nil end
    if to and not CURRENCIES[to] then return nil end
    if not to then to = "CNY" end
    local amount = 1
    if amount_s and #amount_s > 0 then
        amount = tonumber(amount_s)
        if not amount then return nil end
    end
    return amount, from, to
end

-- 必须是全局函数（同 translate 理由）
function exchange(input)
    if input == nil or #input < 1 then return nil end
    if input:sub(-1) ~= " " then return nil end
    local s = input:sub(1, -2)
    local amount, from, to = parse_expr(s)
    if not amount or not from or not to then
        return { "格式: hl [金额]来源币[目标币] 如 hl100usdcny" }
    end
    if not CURRENCIES[from] or not CURRENCIES[to] then
        return { "不支持货币: " .. (CURRENCIES[from] and from or to) }
    end
    log("exchange " .. amount .. " " .. from .. "->" .. to)
    local json = curl_get("https://open.er-api.com/v6/latest/USD", nil, 8)
    if not json then
        log("exchange: curl nil")
        return nil
    end
    if json:find("^curl:") then
        log("exchange: error " .. json:sub(1, 60))
        return nil
    end
    local rate_from = extract_num(json, from)
    local rate_to = extract_num(json, to)
    if not rate_from or not rate_to then
        log("exchange: missing rate " .. from .. "/" .. to)
        return nil
    end
    -- 1 USD = rate_from [from], 1 USD = rate_to [to]
    -- amount [from] = amount / rate_from * rate_to [to]
    local converted = amount / rate_from * rate_to
    local fmt = string.format("%s %s = %.2f %s", amount, from, converted, to)
    log("exchange result: " .. fmt)
    return { fmt }
end

ime.register_command("fy", "translate", "翻译", "none", "中↔英，v fy 文本+空格，或空参+复制文本")
ime.register_command("hl", "exchange", "汇率", "none", "v hl 金额+来源+目标+空格")
