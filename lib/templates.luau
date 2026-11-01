--!strict
-- 模板库模型：预制模板（插件目录，只读）+ 自定义模板（kv），以及筛选与排序。
--
-- 预制模板的元数据放在 .md 的 frontmatter 里，解析器只认自己写出的那几个键。

local util = require("./util")

local M = {}

export type Template = {
	id: string,
	name: string,
	nameEn: string,
	labels: { string },
	body: string,
	builtin: boolean,
	usage: number,
	command: string?,
	hidden: boolean,
}

export type CustomTemplate = {
	id: string,
	name: string,
	labels: { string },
	body: string,
	command: string,
}

export type Flags = {
	hideAllPresets: boolean,
	hidden: { [string]: boolean },
}

export type Scope = "all" | "preset" | "custom"

export type Filter = {
	scope: Scope,
	label: string?,
	query: string?,
	showHidden: boolean,
}

--- 解析一个预制模板文件的内容（frontmatter + 正文）。
function M.parsePreset(text: string): Template?
	local head, body = M.splitFrontmatter(text)
	if not head then
		return nil
	end
	local meta = M.parseFrontmatter(head)
	local id = meta.id
	local name = meta.name
	if not id or not name then
		return nil
	end
	local labels = {}
	if meta.labels and meta.labels ~= "" then
		for part in string.gmatch(meta.labels, "[^,]+") do
			local label = util.trim(part)
			if label ~= "" then
				table.insert(labels, label)
			end
		end
	end
	return {
		id = id,
		name = name,
		nameEn = meta.nameEn or name,
		labels = labels,
		body = util.trim(body),
		builtin = true,
		usage = 0,
		command = nil,
		hidden = false,
	}
end

--- frontmatter 与正文的切分：文件以 "---\n" 开头，其后第一个 "\n---" 行结束 frontmatter。
function M.splitFrontmatter(text: string): (string?, string)
	local head, body = string.match(text, "^%-%-%-\r?\n(.-)\r?\n%-%-%-\r?\n(.*)$")
	if not head then
		return nil, text
	end
	return head, body
end

--- 只认 key: value，value 原样保留（列表用逗号分隔）。
function M.parseFrontmatter(head: string): { [string]: string }
	local meta = {}
	for line in string.gmatch(head, "[^\r\n]+") do
		local key, value = string.match(line, "^([%w_%-]+):%s*(.*)$")
		if key then
			meta[key] = util.trim(value)
		end
	end
	return meta
end

--- 命令名合法性：它既是文件名，也是 omp 的命令名。
function M.validCommandName(name: string): boolean
	return name:match("^[a-z0-9][a-z0-9_-]*$") ~= nil
end

--- 按名字生成一条命令名：prompt-<slug>；slug 为空时返回空串。
function M.suggestCommand(name: string): string
	local slug = util.slug(name)
	if slug == "" then
		return ""
	end
	return "prompt-" .. slug
end

--- 模板生效的命令名：自定义模板用自己的，其余按英文名、名字、id 依次生成。
function M.commandName(t: Template): string
	if t.command and M.validCommandName(t.command) then
		return t.command
	end
	local base = M.suggestCommand(t.nameEn)
	if base == "" then
		base = M.suggestCommand(t.name)
	end
	if base == "" then
		base = M.suggestCommand(t.id)
	end
	if base == "" then
		base = "prompt-t" .. t.id
	end
	return base
end

--- 预制与自定义合并成一张表；usage 与 hidden 从 kv 覆盖。
function M.merge(
	presets: { Template },
	custom: { [string]: CustomTemplate },
	usage: { [string]: number },
	flags: Flags
): { Template }
	local out = {}
	for _, p in presets do
		local t = util.deepCopy(p)
		t.usage = usage[t.id] or 0
		t.hidden = flags.hidden[t.id] == true or flags.hideAllPresets
		table.insert(out, t)
	end
	for id, c in custom do
		table.insert(out, {
			id = id,
			name = c.name,
			nameEn = c.name,
			labels = util.deepCopy(c.labels),
			body = c.body,
			builtin = false,
			usage = usage[id] or 0,
			command = c.command,
			hidden = flags.hidden[id] == true,
		})
	end
	return out
end

--- 筛选：范围 + 标签 + 子串（对名称、英文名与正文做大小写无关匹配）。
function M.filter(list: { Template }, f: Filter): { Template }
	local out = {}
	local query = f.query and util.trim(f.query):lower() or ""
	local label = f.label
	for _, t in ipairs(list) do
		if t.hidden and not f.showHidden then
			continue
		end
		if f.scope == "preset" and not t.builtin then
			continue
		end
		if f.scope == "custom" and t.builtin then
			continue
		end
		if label and not util.contains(t.labels, label) then
			continue
		end
		if query ~= "" then
			local haystack = (t.name .. " " .. t.nameEn .. " " .. table.concat(t.labels, " ") .. " " .. t.body):lower()
			if not string.find(haystack, query, 1, true) then
				continue
			end
		end
		table.insert(out, t)
	end
	return out
end

--- 排序：使用次数降序，同次数按名称排。
function M.sort(list: { Template }): { Template }
	local out = util.deepCopy(list)
	table.sort(out, function(a, b)
		if a.usage ~= b.usage then
			return a.usage > b.usage
		end
		return a.name < b.name
	end)
	return out
end

--- 每个标签带条数，按条数降序、同条数按名称。
function M.labelCounts(list: { Template }): { { label: string, count: number } }
	local counts: { [string]: number } = {}
	for _, t in ipairs(list) do
		for _, l in ipairs(t.labels) do
			counts[l] = (counts[l] or 0) + 1
		end
	end
	local out = {}
	for label, count in pairs(counts) do
		table.insert(out, { label = label, count = count })
	end
	table.sort(out, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.label < b.label
	end)
	return out
end

return M
