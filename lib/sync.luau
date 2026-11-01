--!strict
-- 面板与 omp 命令文件的同步：面板是唯一真源，命令文件是派生产物。
--
-- 只碰插件自己写过的文件（清单在 library.files 里）：用户手写的同名文件既不覆盖也不删除。

local library = require("./library")
local ompcmd = require("./ompcmd")
local templates = require("./templates")
local util = require("./util")

local M = {}

--- 同步全部命令文件。返回命令文件是否变了，以及因为撞上手写文件而跳过的条数。
function M.sync(lib: library.Library, items: { templates.Template }): (boolean, number)
	local dir = ompcmd.commandsDir()
	local wanted: { [string]: templates.Template } = {}
	for _, t in ipairs(items) do
		if not t.hidden then
			wanted[t.id] = t
		end
	end

	local changed = false
	local skipped = 0
	for id, t in pairs(wanted) do
		local name = templates.commandName(t)
		local previous = lib.files[id]
		-- 命令名改过：先删掉旧文件，别留下孤儿。
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
		elseif current ~= nil and previous ~= name then
			-- 同名文件不是我们写的：留着它，报告跳过。
			skipped += 1
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

	return changed, skipped
end

return M
