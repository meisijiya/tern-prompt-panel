--!strict
-- 可编辑文本字段：程序拥有文本，自己维护光标（UTF-16 偏移）。
--
-- tern 的 editor/input 节点只是状态的画布：字符输入、删除、光标移动都在这里做。

local util = require("./util")

local M = {}

export type Field = {
	text: string,
	cursor: number,
}

function M.new(text: string?): Field
	local t = text or ""
	return { text = t, cursor = util.u16Len(t) }
end

--- 在光标处插入一段文本。
function M.insert(f: Field, s: string)
	if s == "" then
		return
	end
	local text, cursor = util.insert16(f.text, f.cursor, s)
	f.text = text
	f.cursor = cursor
end

--- 删除光标前一个字符。
function M.backspace(f: Field)
	local text, cursor = util.backspace(f.text, f.cursor)
	f.text = text
	f.cursor = cursor
end

--- 删除光标后一个字符。
function M.deleteForward(f: Field)
	local text, cursor = util.deleteForward(f.text, f.cursor)
	f.text = text
	f.cursor = cursor
end

function M.moveLeft(f: Field)
	f.cursor = util.moveLeft(f.text, f.cursor)
end

function M.moveRight(f: Field)
	f.cursor = util.moveRight(f.text, f.cursor)
end

function M.moveHome(f: Field)
	f.cursor = util.lineStart16(f.text, f.cursor)
end

function M.moveEnd(f: Field)
	f.cursor = util.lineEnd16(f.text, f.cursor)
end

function M.moveUp(f: Field)
	f.cursor = util.prevLine16(f.text, f.cursor)
end

function M.moveDown(f: Field)
	f.cursor = util.nextLine16(f.text, f.cursor)
end

--- 应用外部（tern 原生编辑）发来的改动：替换 [from, to) 为 text，光标落在 cursor。
function M.splice(f: Field, from: number, to: number, text: string, cursor: number)
	f.text = util.splice16(f.text, from, to, text)
	f.cursor = cursor
end

return M
