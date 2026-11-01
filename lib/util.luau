--!strict
-- 纯逻辑工具：UTF-16 偏移换算、slug、集合操作。
-- 不依赖 tern，可在 luau CLI 下单测。

local M = {}

--- 一个码点占几个 UTF-16 码元。
local function unitsOf(cp: number): number
	return if cp > 0xFFFF then 2 else 1
end

--- 字符串的 UTF-16 长度（码元数）。
function M.u16Len(s: string): number
	local n = 0
	for _, cp in utf8.codes(s) do
		n += unitsOf(cp)
	end
	return n
end

--- UTF-16 偏移 -> 字节偏移（1 起）。落在代理对内部时向下取到该字符起点。
function M.u16ToByte(s: string, off: number): number
	if off <= 0 then
		return 1
	end
	local units = 0
	for p, cp in utf8.codes(s) do
		if off <= units then
			return p
		end
		local w = unitsOf(cp)
		if off < units + w then
			return p
		end
		units += w
	end
	return #s + 1
end

--- 字节偏移（1 起）-> UTF-16 偏移。
function M.byteToU16(s: string, byteOff: number): number
	if byteOff <= 1 then
		return 0
	end
	local units = 0
	for p, cp in utf8.codes(s) do
		if p >= byteOff then
			return units
		end
		units += unitsOf(cp)
	end
	return units
end

--- 用 text 替换 UTF-16 区间 [from, to)。
function M.splice16(s: string, from: number, to: number, text: string): string
	local b1 = M.u16ToByte(s, from)
	local b2 = M.u16ToByte(s, to)
	return s:sub(1, b1 - 1) .. text .. s:sub(b2)
end

--- 在 UTF-16 偏移处插入文本，返回新串与新光标位置。
function M.insert16(s: string, at: number, text: string): (string, number)
	return M.splice16(s, at, at, text), at + M.u16Len(text)
end

--- 删除光标前一个字符（按码点，不劈开代理对）。
function M.backspace(s: string, at: number): (string, number)
	if at <= 0 then
		return s, at
	end
	local prev = M.u16ToByte(s, at - 1)
	return s:sub(1, prev - 1) .. s:sub(M.u16ToByte(s, at)), M.byteToU16(s, prev)
end

--- 删除光标后一个字符。
function M.deleteForward(s: string, at: number): (string, number)
	if at >= M.u16Len(s) then
		return s, at
	end
	local b = M.u16ToByte(s, at + 1)
	local after = M.u16ToByte(s, at + 2)
	return s:sub(1, b - 1) .. s:sub(after), at
end

--- 光标往前一个字符的 UTF-16 位置。
function M.moveLeft(s: string, at: number): number
	if at <= 0 then
		return 0
	end
	return M.byteToU16(s, M.u16ToByte(s, at - 1))
end

--- 光标往后一个字符的 UTF-16 位置。
function M.moveRight(s: string, at: number): number
	if at >= M.u16Len(s) then
		return M.u16Len(s)
	end
	return M.byteToU16(s, M.u16ToByte(s, at + 2))
end

--- 该偏移所在行的起始 UTF-16 偏移。
function M.lineStart16(s: string, at: number): number
	local b = M.u16ToByte(s, at)
	local nl = string.find(s:sub(1, b - 1), "\n", 1, true)
	if not nl then
		return 0
	end
	return M.byteToU16(s, nl + 1)
end

--- 该偏移所在行的结束 UTF-16 偏移（不含换行符）。
function M.lineEnd16(s: string, at: number): number
	local b = M.u16ToByte(s, at)
	local nl = string.find(s:sub(b), "\n", 1, true)
	if not nl then
		return M.u16Len(s)
	end
	return M.byteToU16(s, b + nl - 1)
end

--- 下一个换行符后的 UTF-16 偏移。
function M.nextLine16(s: string, at: number): number
	local b = M.u16ToByte(s, at)
	local nl = string.find(s, "\n", b, true)
	if not nl then
		return at
	end
	return M.byteToU16(s, nl + 1)
end

--- 上一个换行符处的 UTF-16 偏移。
function M.prevLine16(s: string, at: number): number
	local b = M.u16ToByte(s, at)
	local nl = string.find(s:sub(1, b - 1), "\n", 1, true)
	if not nl then
		return at
	end
	return M.byteToU16(s, nl)
end

--- 去掉首尾空白。
function M.trim(s: string): string
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- slug：小写字母数字，其余折成单个连字符。
function M.slug(s: string): string
	local out = ""
	local dash = false
	for i = 1, #s do
		local c = s:sub(i, i):lower()
		if c:match("[a-z0-9]") then
			out ..= c
			dash = false
		elseif not dash and out ~= "" then
			out ..= "-"
			dash = true
		end
	end
	return (out:gsub("-+$", ""))
end

--- 深拷贝一张表（仅 JSON 兼容的值）。
function M.deepCopy<T>(v: T): T
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, val in v do
		out[k] = M.deepCopy(val)
	end
	return out
end

--- 数组里的某项是否存在。
function M.contains(list: { any }, needle: any): boolean
	for _, v in ipairs(list) do
		if v == needle then
			return true
		end
	end
	return false
end

--- 去掉正文里的 {{cursor}} 标记（其余原样保留）。
function M.stripCursor(s: string): string
	return (s:gsub("{{cursor}}", ""))
end

--- 第一个 {{cursor}} 之前的正文；没有标记时返回整个串。
function M.beforeCursor(s: string): string
	local head = string.match(s, "^(.-){{cursor}}")
	return head or s
end

--- 第一个 {{cursor}} 之后的正文；没有标记时返回空串。
function M.afterCursor(s: string): string
	local tail = string.match(s, "{{cursor}}(.*)$")
	return tail or ""
end

return M
