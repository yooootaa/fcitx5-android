--
-- calculator.lua — fcitx5-android Lua 计算器扩展
-- 用法：拼音模式下按 @ 进入快速输入，再输入 js 加算式
-- 直接使用 +-*/ 运算符
-- 例如 @js1+2 → 3
--
local fcitx = require("fcitx")

local function format_number(n)
    if n == math.floor(n) then
        return tostring(math.floor(n))
    else
        return tostring(n)
    end
end

function calculator_compute(input)
    if input == nil or input == "" then
        return nil
    end

    local expr = input

    -- 安全白名单：只允许数字和 +-*/()% 运算符及空白
    if not expr:match("^[%d%+%-%(%)%*%/%%.%s]+$") then
        return nil
    end

    -- 必须包含至少一个运算符才显示结果
    if not expr:match("[%+%-%*/%%]") then
        return nil
    end

    local fn = load("return " .. expr)
    if fn == nil then
        return nil
    end

    local ok, result = pcall(fn)
    if not ok or type(result) ~= "number" then
        return nil
    end

    local result_str = format_number(result)

    return {
        result_str,
        expr .. "=" .. result_str,
    }
end

-- leading=none: 数字键进入缓冲区而非选词
ime.register_command("js", "calculator_compute", "计算", "none", "输入算式如 1+2")
