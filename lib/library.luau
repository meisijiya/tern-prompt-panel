--!strict
-- 模板库的真源：预制模板在插件目录（只读），用户增量在 tern.kv。
--
-- kv 的读会因半写入而抛错，两个半边都读它，所以每次读都走 pcall。

local templates = require("./templates")
local util = require("./util")

local M = {}

export type CustomTemplate = templates.CustomTemplate

export type Library = {
	custom: { [string]: CustomTemplate },
	usage: { [string]: number },
	hidden: { [string]: boolean },
	hideAllPresets: boolean,
	files: { [string]: string },
	nextId: number,
	seq: number,
}

local KEY = "library"

local function empty(): Library
	return {
		custom = {},
		usage = {},
		hidden = {},
		hideAllPresets = false,
		files = {},
		nextId = 1,
		seq = 0,
	}
end

M.empty = empty

--- 读库；读失败（半写入）时退回空库，绝不把异常抛给调用方。
function M.read(): Library
	local ok, value = pcall(tern.kv.get, KEY)
	if not ok or type(value) ~= "table" then
		return empty()
	end
	local lib = empty()
	for id, t in pairs(value.custom or {}) do
		if type(t) == "table" and type(t.name) == "string" then
			local labels: { string } = {}
			for _, l in ipairs(t.labels or {}) do
				if type(l) == "string" then
					table.insert(labels, l)
				end
			end
			lib.custom[id] = {
				id = id,
				name = t.name,
				labels = labels,
				body = type(t.body) == "string" and t.body or "",
				command = type(t.command) == "string" and t.command or "",
			}
		end
	end
	for id, n in pairs(value.usage or {}) do
		if type(n) == "number" then
			lib.usage[id] = n
		end
	end
	for id in pairs(value.hidden or {}) do
		lib.hidden[id] = true
	end
	lib.hideAllPresets = value.hideAllPresets == true
	for id, name in pairs(value.files or {}) do
		if type(name) == "string" then
			lib.files[id] = name
		end
	end
	if type(value.nextId) == "number" then
		lib.nextId = value.nextId
	end
	if type(value.seq) == "number" then
		lib.seq = value.seq
	end
	return lib
end

--- 写库。整库一个键：两个半边同时写同一个文件会互相覆盖，所以只有宿主半边写。
function M.write(lib: Library)
	tern.kv.set(KEY, {
		custom = lib.custom,
		usage = lib.usage,
		hidden = lib.hidden,
		hideAllPresets = lib.hideAllPresets,
		files = lib.files,
		nextId = lib.nextId,
		seq = lib.seq,
	})
end

--- 自定义模板的默认命令名：prompt-<slug>。
function M.defaultCommand(name: string): string
	local slug = util.slug(name)
	if slug == "" then
		return ""
	end
	return "prompt-" .. slug
end

--- 命令名合法性：只允许小写字母、数字、连字符和下划线（它是文件名，也是 omp 的命令名）。
function M.validCommandName(name: string): boolean
	return name:match("^[a-z0-9][a-z0-9_-]*$") ~= nil
end

return M
