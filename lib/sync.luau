--!strict
-- 面板与 omp 命令文件的同步：面板是唯一真源，命令文件是派生产物。
--
-- 只删插件自己写过的文件（清单在 library.files 里），用户手写的同名文件不动。

local library = require("./library")
local ompcmd = require("./ompcmd")
local templates = require("./templates")
local util = require("./util")

local M = {}

--- 模板生效的命令名：自定义模板用它自己的，预制模板按英文名生成。
function M.commandName(t: templates.Template): string
	if t.command and library.validCommandName(t.command) then
		return t.command
	end
	if t.builtin then
		return templates.defaultCommand(t)
	end
	local fallback = library.defaultCommand(t.name)
	if fallback ~= "" then
		return fallback
	end
	return "prompt-t" .. t.id
end

--- 同步全部命令文件。返回是否有文件变动（变了就要在 omp 里重新加载命令）。
function M.sync(lib: library.Library, items: { templates.Template }): boolean
	local dir = ompcmd.commandsDir()
	local wanted: { [string]: templates.Template } = {}
	for _, t in ipairs(items) do
		if not t.hidden then
			wanted[t.id] = t
		end
	end

	local changed = false
	for id, t in pairs(wanted) do
		local name = M.commandName(t)
		-- 命令名改过：先删掉旧文件，别留下孤儿。
		local previous = lib.files[id]
		if previous and previous ~= name then
			ompcmd.remove(dir, previous)
			changed = true
		end
		local content = ompcmd.fileContent(t.name, nil, util.stripCursor(t.body))
		local path = dir .. "/" .. name .. ".md"
		local current: string? = nil
		if tern.fs.exists(path) then
			local ok, text = pcall(tern.fs.read, path)
			if ok then
				current = text
			end
		end
		if current == content then
			lib.files[id] = name
		elseif ompcmd.write(dir, name, content) then
			lib.files[id] = name
			changed = true
		end
	end

	for id, name in pairs(lib.files) do
		if not wanted[id] then
			ompcmd.remove(dir, name)
			lib.files[id] = nil
			changed = true
		end
	end

	return changed
end

return M
