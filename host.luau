--!strict
-- 提示词面板（宿主半边）：模板列表、筛选、编辑，以及与 omp 命令文件的同步。
--
-- 面板是模板库的唯一真源；omp 的命令文件是派生结果，写在 ~/.omp/agent/commands/。
-- 用户增量（自定义模板、使用次数、屏蔽、命令名）存 tern.kv，预制模板在插件目录里只读。
--
-- 键由插件自己处理：块没有开启 edit 特性，所有按键都进 key handler，
-- 所以文本、光标都由这里维护（偏移是 UTF-16 码元）。

local ui = tern.ui
local catalog = require("./lib/catalog")
local field = require("./lib/field")
local library = require("./lib/library")
local sync = require("./lib/sync")
local templates = require("./lib/templates")
local util = require("./lib/util")

local SCOPES: { templates.Scope } = { "all", "preset", "custom" }
local SCOPE_LABEL = { all = "全部", preset = "预制", custom = "自定义" }
local LIST_KEY = "items"
local LIST_ID = "main." .. LIST_KEY .. "."
local ACTION_KEY = "action"

local FIELDS = { "name", "labels", "command", "body" }
local FIELD_AT = { ["main.f_name"] = 1, ["main.f_labels"] = 2, ["main.f_command"] = 3, ["main.f_body"] = 4 }
local FIELD_LABEL = { name = "名称", labels = "标签", command = "命令名", body = "正文" }

type Draft = {
	id: string,
	name: field.Field,
	labels: field.Field,
	command: field.Field,
	body: field.Field,
	at: number,
}

type State = {
	lib: library.Library,
	mode: string, -- browse | search | edit
	sel: string?,
	scope: templates.Scope,
	label: string?,
	showHidden: boolean,
	query: field.Field,
	draft: Draft?,
	message: string?,
}

--- 全部模板（预制 + 自定义），带上 kv 里的使用次数、命令名与屏蔽状态。
local function allTemplates(state: State): { templates.Template }
	return templates.merge(catalog.load(), state.lib.custom, state.lib.usage, {
		hideAllPresets = state.lib.hideAllPresets,
		hidden = state.lib.hidden,
	})
end

--- 当前筛选下的模板列表：范围 + 标签 + 子串，按使用次数降序。
local function visibleTemplates(state: State): { templates.Template }
	return templates.sort(templates.filter(allTemplates(state), {
		scope = state.scope,
		label = state.label,
		query = state.query.text,
		showHidden = state.showHidden,
	}))
end

--- 选中的模板：state.sel 不在当前列表里时退回第一行。
local function selectedTemplate(state: State): templates.Template?
	local visible = visibleTemplates(state)
	if #visible == 0 then
		return nil
	end
	for _, t in ipairs(visible) do
		if t.id == state.sel then
			return t
		end
	end
	return visible[1]
end

--- 把库写回 kv，并按需同步 omp 命令文件；返回命令文件是否变了。
local function persist(state: State): boolean
	local changed = sync.sync(state.lib, allTemplates(state))
	library.write(state.lib)
	return changed
end

--- 记一次使用。
local function countUse(state: State, id: string)
	state.lib.usage[id] = (state.lib.usage[id] or 0) + 1
end

--- 应用模板：复制正文到剪贴板，并提示它的 omp 命令名。
local function applyTemplate(state: State, t: templates.Template, cx: BlockCx)
	cx:copy(util.stripCursor(t.body))
	countUse(state, t.id)
	local changed = persist(state)
	local name = sync.commandName(t)
	cx:toast("success", "已复制：" .. t.name, "/" .. name)
	state.message = if changed
		then "已复制 /" .. name .. "；命令文件已更新，omp 里执行 /reload-plugins"
		else "已复制 /" .. name
end

--- 提交给聚焦的 omp agent：由窗口半边执行（host 写 kv，window 轮询）。
local function submitTemplate(state: State, t: templates.Template, cx: BlockCx)
	countUse(state, t.id)
	state.lib.seq = state.lib.seq + 1
	library.write(state.lib)
	tern.kv.set(ACTION_KEY, {
		seq = state.lib.seq,
		kind = "submit",
		pane = cx.pane,
		body = util.stripCursor(t.body),
		name = t.name,
	})
	cx:toast("info", "已提交：" .. t.name, "发送到聚焦的 omp agent")
	state.message = "已提交 " .. t.name
end

--- 新建或编辑一个自定义模板。
local function openEditor(state: State, id: string)
	local custom = state.lib.custom[id]
	local draft: Draft
	if custom then
		draft = {
			id = id,
			name = field.new(custom.name),
			labels = field.new(table.concat(custom.labels, ",")),
			command = field.new(custom.command),
			body = field.new(custom.body),
			at = 1,
		}
	else
		draft = {
			id = id,
			name = field.new(""),
			labels = field.new(""),
			command = field.new(""),
			body = field.new(""),
			at = 1,
		}
	end
	state.draft = draft
	state.mode = "edit"
	state.message = nil
end

--- 造一个新的自定义模板 id。
local function nextCustomId(state: State): string
	local id = "c" .. tostring(state.lib.nextId)
	state.lib.nextId = state.lib.nextId + 1
	return id
end

--- 一条没被别的模板占着的命令名：先按名字生成，撞了就退回 id。
local function uniqueCommand(state: State, id: string, name: string): string
	local taken: { [string]: boolean } = {}
	for _, t in ipairs(allTemplates(state)) do
		taken[sync.commandName(t)] = true
	end
	local base = library.defaultCommand(name)
	if base ~= "" and not taken[base] then
		return base
	end
	local candidate = "prompt-" .. id
	local n = 1
	while taken[candidate] do
		n += 1
		candidate = "prompt-" .. id .. "-" .. tostring(n)
	end
	return candidate
end

--- 把选中的模板复制成自定义模板，进入编辑。
local function copyToCustom(state: State, t: templates.Template)
	local id = nextCustomId(state)
	state.lib.custom[id] = {
		id = id,
		name = t.name,
		labels = util.deepCopy(t.labels),
		body = t.body,
		command = uniqueCommand(state, id, t.name),
	}
	state.sel = id
	persist(state)
	openEditor(state, id)
	state.message = "已复制为自定义模板"
end

--- 保存编辑中的模板。返回错误说明，成功返回 nil。
local function saveDraft(state: State, draft: Draft): string?
	local name = util.trim(draft.name.text)
	if name == "" then
		return "名称不能为空"
	end
	if util.trim(draft.body.text) == "" then
		return "正文不能为空"
	end
	local labels: { string } = {}
	for part in string.gmatch(draft.labels.text, "[^,，]+") do
		local label = util.trim(part)
		if label ~= "" then
			table.insert(labels, label)
		end
	end
	if #labels > 3 then
		return "标签最多 3 个"
	end
	local command = util.trim(draft.command.text)
	if command == "" then
		command = uniqueCommand(state, draft.id, name)
	end
	if not library.validCommandName(command) then
		return "命令名只能是小写字母、数字、- 和 _"
	end
	for _, t in ipairs(allTemplates(state)) do
		if t.id ~= draft.id and sync.commandName(t) == command then
			return "命令名 /" .. command .. " 已被占用"
		end
	end
	state.lib.custom[draft.id] = {
		id = draft.id,
		name = name,
		labels = labels,
		body = draft.body.text,
		command = command,
	}
	state.draft = nil
	state.mode = "browse"
	state.sel = draft.id
	return nil
end

local function deleteTemplate(state: State, t: templates.Template)
	if t.builtin then
		state.message = "预制模板不能删除，可以屏蔽"
		return
	end
	state.lib.custom[t.id] = nil
	state.lib.hidden[t.id] = nil
	local changed = persist(state)
	state.sel = nil
	state.message = if changed
		then "已删除 " .. t.name .. "；omp 里执行 /reload-plugins"
		else "已删除 " .. t.name
end

local function toggleHidden(state: State, t: templates.Template)
	if state.lib.hidden[t.id] then
		state.lib.hidden[t.id] = nil
		state.message = "已恢复 " .. t.name
	else
		state.lib.hidden[t.id] = true
		state.message = "已屏蔽 " .. t.name
	end
	if persist(state) then
		state.message ..= "；omp 里执行 /reload-plugins"
	end
end

local function cycleScope(state: State)
	for i, s in ipairs(SCOPES) do
		if s == state.scope then
			state.scope = SCOPES[(i % #SCOPES) + 1]
			return
		end
	end
	state.scope = "all"
end

local function cycleLabel(state: State)
	local labels = templates.allLabels(allTemplates(state))
	if #labels == 0 then
		state.label = nil
		return
	end
	if not state.label then
		state.label = labels[1]
		return
	end
	for i, l in ipairs(labels) do
		if l == state.label then
			state.label = labels[(i % #labels) + 1]
			return
		end
	end
	state.label = labels[1]
end

--- 键入一个字符或一段文本。
local function typeInto(f: field.Field, key: Key): boolean
	if key.ctrl or key.alt or key.meta then
		return false
	end
	if key.name == "paste" then
		field.insert(f, key.text or "")
		return true
	end
	if key.text and key.text ~= "" then
		field.insert(f, key.text)
		return true
	end
	return false
end

--- 光标与删除类按键，作用于某个字段。
local function editField(f: field.Field, key: Key): boolean
	if key.ctrl or key.alt or key.meta then
		return false
	end
	if key.name == "backspace" then
		field.backspace(f)
		return true
	elseif key.name == "delete" then
		field.deleteForward(f)
		return true
	elseif key.name == "left" then
		field.moveLeft(f)
		return true
	elseif key.name == "right" then
		field.moveRight(f)
		return true
	elseif key.name == "home" then
		field.moveHome(f)
		return true
	elseif key.name == "end" then
		field.moveEnd(f)
		return true
	elseif key.name == "up" then
		field.moveUp(f)
		return true
	elseif key.name == "down" then
		field.moveDown(f)
		return true
	end
	return false
end

local function draftField(draft: Draft, at: number): field.Field
	local which = FIELDS[at]
	if which == "name" then
		return draft.name
	elseif which == "labels" then
		return draft.labels
	elseif which == "command" then
		return draft.command
	end
	return draft.body
end

--- 编辑态：当前字段。
local function currentField(state: State): field.Field?
	local draft = state.draft
	if not draft then
		return nil
	end
	return draftField(draft, draft.at)
end

local function browseView(state: State, cx: BlockCx): Node
	local visible = visibleTemplates(state)
	local items: { any } = {}
	for _, t in ipairs(visible) do
		local detail = table.concat(t.labels, " · ")
		if t.usage > 0 then
			detail = detail .. " · 用过 " .. tostring(t.usage) .. " 次"
		end
		table.insert(items, {
			label = t.name,
			detail = detail,
			value = "/" .. sync.commandName(t),
			icon = if t.builtin then "prompt" else "note",
			tone = if t.hidden then "muted" else nil,
		})
	end
	local list = ui.list(items)
	local kids = list.c or {}
	for i, t in ipairs(visible) do
		local p: { [string]: any } = kids[i].p or {}
		p.key = t.id
		kids[i].p = p
	end
	local lp: { [string]: any } = list.p or {}
	lp.key = LIST_KEY
	lp.empty = { ui.span("没有匹配的模板", "muted") }
	lp.max = { lines = math.max(4, cx.rows - 8) }
	local current = selectedTemplate(state)
	lp.selected = if current then LIST_ID .. current.id else nil
	list.p = lp

	local header: { Span | string } = {
		ui.span("提示词面板", "strong"),
		ui.span("  " .. tostring(#visible) .. " / " .. tostring(#allTemplates(state)) .. " 条", "muted"),
		ui.span("  范围 " .. SCOPE_LABEL[state.scope], "muted"),
	}
	if state.label then
		table.insert(header, ui.span("  标签 " .. state.label, "muted"))
	end
	if state.showHidden then
		table.insert(header, ui.span("  含已屏蔽", "muted"))
	end
	if state.lib.hideAllPresets then
		table.insert(header, ui.span("  已屏蔽全部预制", "warning"))
	end

	return ui.col({
		ui.text(header),
		ui.node("input", {
			key = "f_query",
			text = state.query.text,
			cursor = state.query.cursor,
			placeholder = "搜索名称、标签或正文（/ 进入搜索）",
		}),
		list,
	})
end

local function editView(state: State): Node
	local draft = state.draft :: Draft
	local label: { Span | string } = {
		ui.span(if state.lib.custom[draft.id] then "编辑模板" else "新建模板", "strong"),
		ui.span("  " .. (state.message or "Tab 切换字段，正文里 Enter 保存，Esc 取消"), "muted"),
	}
	return ui.col({
		ui.text(label),
		ui.text({ ui.span(FIELD_LABEL.name, "muted") }),
		ui.node("input", { key = "f_name", text = draft.name.text, cursor = draft.name.cursor }),
		ui.text({ ui.span(FIELD_LABEL.labels, "muted") }),
		ui.node("input", { key = "f_labels", text = draft.labels.text, cursor = draft.labels.cursor }),
		ui.text({ ui.span(FIELD_LABEL.command, "muted") }),
		ui.node("input", { key = "f_command", text = draft.command.text, cursor = draft.command.cursor }),
		ui.text({ ui.span(FIELD_LABEL.body, "muted") }),
		ui.node("editor", {
			key = "f_body",
			text = draft.body.text,
			cursor = draft.body.cursor,
			maxLines = 8,
			placeholder = "模板正文",
		}),
	})
end

local function badge(text: string, tone: string, act: string): Node
	local node = ui.badge(text, tone)
	local p: { [string]: any } = node.p or {}
	p.actions = { click = act }
	node.p = p
	return node
end

local function dockView(state: State): Node
	if state.mode == "edit" then
		local editRows: { Node } = {
			ui.text({ ui.span("正文里 Enter 保存、Shift+Enter 换行  ·  Esc 取消  ·  Tab 切换字段", "dim") }),
		}
		if state.message then
			table.insert(editRows, ui.text({ ui.span(state.message, "warning") }))
		end
		return ui.col(editRows)
	end
	local rows: { Node } = {
		ui.row({
			badge("应用", "accent", "apply"),
			badge("编辑", "neutral", "edit"),
			badge("复制为自定义", "neutral", "copy"),
			badge("新建", "neutral", "new"),
			badge("删除", "neutral", "delete"),
			badge("同步命令", "neutral", "sync"),
		}),
		ui.text({
			ui.span(
				"Enter 应用 · a 提交给 agent · e 编辑 · c 复制 · n 新建 · d 删除 · "
					.. "f 范围 · l 标签 · h 屏蔽 · H 全屏蔽 · v 含已屏蔽 · / 搜索 · r 同步",
				"dim"
			),
		}),
	}
	if state.mode == "search" then
		table.insert(rows, ui.text({ ui.span("搜索中：输入关键字，Esc 或 Enter 回到列表", "accent") }))
	end
	if state.message then
		table.insert(rows, ui.text({ ui.span(state.message, "muted") }))
	end
	return ui.col(rows)
end

local function moveSelection(state: State, delta: number)
	local visible = visibleTemplates(state)
	if #visible == 0 then
		return
	end
	local index = 1
	for i, t in ipairs(visible) do
		if t.id == state.sel then
			index = i
			break
		end
	end
	local nextIndex = math.clamp(index + delta, 1, #visible)
	state.sel = visible[nextIndex].id
end

local function browseKey(state: State, key: Key, cx: BlockCx): boolean?
	if state.mode == "search" then
		if key.name == "escape" or key.name == "enter" then
			state.mode = "browse"
			return true
		end
		if editField(state.query, key) then
			return true
		end
		if typeInto(state.query, key) then
			return true
		end
		return false
	end

	local k = key.text or key.name
	if key.name == "up" or k == "k" then
		moveSelection(state, -1)
	elseif key.name == "down" or k == "j" then
		moveSelection(state, 1)
	elseif key.name == "home" or k == "g" then
		local visible = visibleTemplates(state)
		if #visible > 0 then
			state.sel = visible[1].id
		end
	elseif key.name == "end" or k == "G" then
		local visible = visibleTemplates(state)
		if #visible > 0 then
			state.sel = visible[#visible].id
		end
	elseif key.name == "enter" then
		local t = selectedTemplate(state)
		if t then
			applyTemplate(state, t, cx)
		end
	elseif k == "a" then
		local t = selectedTemplate(state)
		if t then
			submitTemplate(state, t, cx)
		end
	elseif k == "e" then
		local t = selectedTemplate(state)
		if t and not t.builtin then
			openEditor(state, t.id)
		elseif t then
			state.message = "预制模板只读，可复制为自定义后编辑"
		end
	elseif k == "c" then
		local t = selectedTemplate(state)
		if t then
			copyToCustom(state, t)
		end
	elseif k == "n" then
		local id = nextCustomId(state)
		openEditor(state, id)
	elseif k == "d" then
		local t = selectedTemplate(state)
		if t then
			deleteTemplate(state, t)
		end
	elseif k == "f" then
		cycleScope(state)
	elseif k == "l" then
		cycleLabel(state)
	elseif k == "h" then
		local t = selectedTemplate(state)
		if t then
			toggleHidden(state, t)
		end
	elseif k == "H" then
		state.lib.hideAllPresets = not state.lib.hideAllPresets
		persist(state)
		state.message = if state.lib.hideAllPresets then "已屏蔽全部预制模板" else "已恢复全部预制模板"
	elseif k == "v" then
		state.showHidden = not state.showHidden
	elseif k == "r" then
		local changed = persist(state)
		state.message = if changed then "命令文件已更新" else "命令文件没有变化"
	elseif k == "/" then
		state.mode = "search"
	else
		return false
	end
	return true
end

local function editKey(state: State, key: Key): boolean?
	local draft = state.draft
	if not draft then
		return false
	end
	if key.name == "escape" then
		state.draft = nil
		state.mode = "browse"
		state.message = nil
		return true
	end
	if key.name == "tab" then
		draft.at = ((draft.at - 1 + (if key.shift then -1 else 1)) % #FIELDS) + 1
		return true
	end
	local f = currentField(state)
	if not f then
		return false
	end
	if key.name == "enter" then
		if FIELDS[draft.at] ~= "body" then
			draft.at = (draft.at % #FIELDS) + 1
		elseif key.shift then
			field.insert(f, "\n")
		else
			local err = saveDraft(state, draft)
			if err then
				state.message = err
				return true
			end
			local changed = persist(state)
			state.message = if changed
				then "已保存 " .. state.lib.custom[draft.id].name .. "；命令文件已更新，omp 里执行 /reload-plugins"
				else "已保存 " .. state.lib.custom[draft.id].name
			state.mode = "browse"
		end
		return true
	end
	if editField(f, key) then
		return true
	end
	if typeInto(f, key) then
		return true
	end
	return false
end

tern.block.define("prompts", {
	init = function(_cx: BlockCx, _args: { string }, saved: any): State
		local state: State = {
			lib = library.read(),
			mode = "browse",
			sel = nil,
			scope = "all",
			label = nil,
			showHidden = false,
			query = field.new(""),
			draft = nil,
			message = nil,
		}
		if type(saved) == "table" then
			state.scope = saved.scope :: templates.Scope
			state.label = saved.label
			state.showHidden = saved.showHidden == true
			state.sel = saved.sel
			state.query = field.new(saved.query or "")
		end
		-- 命令文件在面板第一次打开时就落地，之后改动即写盘。
		persist(state)
		return state
	end,

	title = function(state: State): string
		return string.format("提示词面板 (%d)", #visibleTemplates(state))
	end,

	view = function(state: State, cx: BlockCx): BlockView
		local main = if state.mode == "edit" then editView(state) else browseView(state, cx)
		return { main = main, dock = dockView(state) }
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		if state.mode == "edit" then
			return editKey(state, key, cx)
		end
		return browseKey(state, key, cx)
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx)
		if (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			local item = ev.item
			state.sel = if string.sub(item, 1, #LIST_ID) == LIST_ID then string.sub(item, #LIST_ID + 1) else item
			if ev.ev == "activate" then
				local t = selectedTemplate(state)
				if t then
					applyTemplate(state, t, cx)
				end
			end
			return
		end
		if ev.ev == "focus" and type(ev.id) == "string" then
			if ev.id == "main.f_query" then
				state.mode = "search"
			elseif state.mode == "edit" and FIELD_AT[ev.id] and state.draft then
				state.draft.at = FIELD_AT[ev.id]
			end
			return
		end
		if ev.ev ~= "action" then
			return
		end
		local t = selectedTemplate(state)
		if ev.act == "apply" then
			if t then
				applyTemplate(state, t, cx)
			end
		elseif ev.act == "edit" then
			if t and not t.builtin then
				openEditor(state, t.id)
			elseif t then
				state.message = "预制模板只读，可复制为自定义后编辑"
			end
		elseif ev.act == "copy" then
			if t then
				copyToCustom(state, t)
			end
		elseif ev.act == "new" then
			local id = nextCustomId(state)
			openEditor(state, id)
		elseif ev.act == "delete" then
			if t then
				deleteTemplate(state, t)
			end
		elseif ev.act == "sync" then
			local changed = persist(state)
			state.message = if changed then "命令文件已更新" else "命令文件没有变化"
		end
	end,

	save = function(state: State): any
		return {
			scope = state.scope,
			label = state.label,
			showHidden = state.showHidden,
			sel = state.sel,
			query = state.query.text,
		}
	end,
})
