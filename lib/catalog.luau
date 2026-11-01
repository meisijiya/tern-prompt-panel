--!strict
-- 预制模板目录读取：插件目录下的 presets/*.md（只读）。
--
-- 预制模板随插件分发，用户增量在 tern.kv；这里只负责把 .md 解析成模板。

local templates = require("./templates")

local M = {}

local cache: { templates.Template }? = nil

--- 读出全部预制模板，按 id 排序；读失败的文件跳过。
function M.load(): { templates.Template }
	if cache then
		return cache
	end
	local out = {}
	local ok, names = pcall(tern.fs.list, "presets")
	if ok then
		for _, name in names do
			if name:sub(-3) == ".md" then
				local readOk, text = pcall(tern.fs.read, "presets/" .. name)
				if readOk then
					local t = templates.parsePreset(text)
					if t then
						table.insert(out, t)
					end
				end
			end
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	cache = out
	return out
end

return M
