--!strict
-- 提示词面板（宿主半边）：模板列表、筛选、预览、编辑，以及与 omp 命令文件的同步。
--
-- 面板是模板库的唯一真源；omp 的命令文件是派生结果，写在 ~/.omp/agent/commands/。
-- 用户增量（自定义模板、使用次数、屏蔽、命令名）存 tern.kv，预制模板在插件目录里只读。
--
-- 键由插件自己处理：块没有开启 edit 特性，所有按键都进 key handler，
-- 所以文本、光标都由这里维护（偏移是 UTF-16 码元）。

local ui = tern.ui
local field = require("./lib/field")
local library = require("./lib/library")
local sync = require("./lib/sync")
local templates = require("./lib/templates")
local util = require("./lib/util")

local SCOPES: { templates.Scope } = { "all", "preset", "custom" }
local SCOPE_LABEL = { all = "全部", preset = "预制模板", custom = "自定义模板" }
local LIST_KEY = "items"
local LIST_ID = "main." .. LIST_KEY .. "."
local ACTION_KEY = "action"
-- 预览最多显示多少行正文。
local PREVIEW_LINES = 14

local FIELDS = {
	{ key = "name", id = "main.f_name", label = "名称" },
	{ key = "labels", id = "main.f_labels", label = "标签" },
	{ key = "command", id = "main.f_command", label = "命令名" },
	{ key = "body", id = "main.f_body", label = "正文" },
}

type Mode = "browse" | "search" | "edit"

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
	mode: Mode,
	sel: string?,
	scope: templates.Scope,
	label: string?,
	showHidden: boolean,
	preview: boolean,
	query: field.Field,
	draft: Draft?,
	-- 刚删掉的自定义模板，留一个位置给撤回。
	trash: templates.CustomTemplate?,
	message: string?,
}

--- 全部模板（预制 + 自定义），带上 kv 里的使用次数与屏蔽状态。
local function allTemplates(state: State): { templates.Template }
	return library.templates(state.lib)
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

--- 把库写回 kv，并按需同步 omp 命令文件。
local function persist(state: State): (boolean, number)
	local changed, skipped = sync.sync(state.lib, allTemplates(state))
	library.write(state.lib)
	return changed, skipped
end

--- 动作提示：命令文件变了、或撞上手写文件时补一句。
local function withSync(text: string, changed: boolean, skipped: number): string
	if skipped > 0 then
		return text .. "；" .. tostring(skipped) .. " 个命令名与手写文件冲突，已跳过"
	end
	if changed then
		return text .. "；命令文件已更新，omp 里执行 /reload-plugins"
	end
	return text
end

--- 记一次使用。
local function countUse(state: State, id: string)
	state.lib.usage[id] = (state.lib.usage[id] or 0) + 1
end

--- 插入模板：复制正文，并请窗口半边把它打进聚焦的 omp agent 的输入框。
local function insertTemplate(state: State, t: templates.Template, cx: BlockCx)
	countUse(state, t.id)
	cx:copy(util.stripCursor(t.body))
	state.lib.seq += 1
	library.write(state.lib)
	tern.kv.set(ACTION_KEY, {
		seq = state.lib.seq,
		kind = "insert",
		pane = cx.pane,
		body = util.stripCursor(t.body),
		name = t.name,
	})
	local name = templates.commandName(t)
	cx:toast("success", "已复制：" .. t.name, "/" .. name)
	state.message = "已复制 /" .. name
end

--- 提交给聚焦的 omp agent：由窗口半边执行（host 写 kv，window 轮询）。
local function submitTemplate(state: State, t: templates.Template, cx: BlockCx)
	countUse(state, t.id)
	state.lib.seq += 1
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
	state.lib.nextId += 1
	return id
end

--- 一条没被别的模板占着的命令名：先按名字生成，撞了就加序号。
local function uniqueCommand(state: State, id: string, name: string): string
	local taken: { [string]: boolean } = {}
	for _, t in ipairs(allTemplates(state)) do
		taken[templates.commandName(t)] = true
	end
	local base = templates.suggestCommand(name)
	if base == "" then
		base = "prompt-" .. id
	end
	local candidate = base
	local n = 1
	while taken[candidate] do
		n += 1
		candidate = base .. "-" .. tostring(n)
	end
	return candidate
end

--- 把选中的模板复制成自定义模板，进入编辑。
local function copyToCustom(state: State, t: templates.Template)
	local id = nextCustomId(state)
	local name = if t.nameEn ~= "" then t.nameEn else t.name
	state.lib.custom[id] = {
		id = id,
		name = t.name,
		labels = util.deepCopy(t.labels),
		body = t.body,
		command = uniqueCommand(state, id, name),
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
	if not templates.validCommandName(command) then
		return "命令名只能是小写字母、数字、- 和 _"
	end
	for _, t in ipairs(allTemplates(state)) do
		if t.id ~= draft.id and templates.commandName(t) == command then
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
	state.trash = util.deepCopy(state.lib.custom[t.id])
	state.lib.custom[t.id] = nil
	state.lib.hidden[t.id] = nil
	local changed, skipped = persist(state)
	state.sel = nil
	state.message = withSync("已删除 " .. t.name .. "，按 u 撤回", changed, skipped)
end

--- 撤回最近一次删除。
local function undoDelete(state: State)
	local t = state.trash
	if not t then
		state.message = "没有可撤回的删除"
		return
	end
	if state.lib.custom[t.id] then
		state.message = "同 id 的模板已存在，撤回跳过"
		return
	end
	state.lib.custom[t.id] = t
	state.trash = nil
	state.sel = t.id
	local changed, skipped = persist(state)
	state.message = withSync("已恢复 " .. t.name, changed, skipped)
end

local function toggleHidden(state: State, t: templates.Template)
	local text: string
	if state.lib.hidden[t.id] then
		state.lib.hidden[t.id] = nil
		text = "已恢复 " .. t.name
	else
		state.lib.hidden[t.id] = true
		text = "已屏蔽 " .. t.name
	end
	local changed, skipped = persist(state)
	state.message = withSync(text, changed, skipped)
end

local function resetUsage(state: State)
	state.lib.usage = {}
	local changed, skipped = persist(state)
	state.message = withSync("已重置使用次数", changed, skipped)
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
	local which = FIELDS[at].key
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

--- 正文按行截断，返回截断后的文本与是否还有更多。
local function clipLines(text: string, maxLines: number): (string, boolean)
	local out: { string } = {}
	local n = 0
	for line in string.gmatch(text .. "\n", "(.-)\n") do
		if n >= maxLines then
			return table.concat(out, "\n"), true
		end
		table.insert(out, line)
		n += 1
	end
	return table.concat(out, "\n"), false
end

--- 选中模板的预览：命令名、标签、使用次数和正文。
local function previewView(t: templates.Template): Node
	local head: { Span | string } = {
		ui.span(t.name, "strong"),
		ui.span("  /" .. templates.commandName(t), "muted"),
	}
	if #t.labels > 0 then
		table.insert(head, ui.span("  " .. table.concat(t.labels, " · "), "muted"))
	end
	if t.usage > 0 then
		table.insert(head, ui.span("  用过 " .. tostring(t.usage) .. " 次", "muted"))
	end
	local body, clipped = clipLines(util.stripCursor(t.body), PREVIEW_LINES)
	local kids: { Node } = { ui.text(head), ui.md(body) }
	if clipped then
		table.insert(kids, ui.text({ ui.span("…", "dim") }))
	end
	return ui.col(kids)
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
			value = "/" .. templates.commandName(t),
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
	lp.max = { lines = math.max(4, cx.rows - (if state.preview then PREVIEW_LINES + 10 else 8)) }
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

	local body: { Node } = {
		ui.text(header),
		ui.node("input", {
			key = "f_query",
			text = state.query.text,
			cursor = state.query.cursor,
			placeholder = "搜索名称、标签或正文（/ 进入搜索）",
		}),
		list,
	}
	if state.preview and current then
		table.insert(body, previewView(current))
	end
	return ui.col(body)
end

local function editView(state: State): Node
	local draft = state.draft :: Draft
	local label: { Span | string } = {
		ui.span(if state.lib.custom[draft.id] then "编辑模板" else "新建模板", "strong"),
		ui.span("  " .. (state.message or "Tab 切换字段，正文里 Enter 保存，Esc 取消"), "muted"),
	}
	local kids: { Node } = {
		ui.text(label),
		ui.text({ ui.span(FIELDS[1].label, "muted") }),
		ui.node("input", { key = "f_name", text = draft.name.text, cursor = draft.name.cursor }),
		ui.text({ ui.span(FIELDS[2].label, "muted") }),
		ui.node("input", { key = "f_labels", text = draft.labels.text, cursor = draft.labels.cursor }),
		ui.text({ ui.span(FIELDS[3].label, "muted") }),
		ui.node("input", { key = "f_command", text = draft.command.text, cursor = draft.command.cursor }),
		ui.text({ ui.span(FIELDS[4].label, "muted") }),
		ui.node("editor", {
			key = "f_body",
			text = draft.body.text,
			cursor = draft.body.cursor,
			maxLines = 8,
			placeholder = "模板正文",
		}),
	}
	return ui.col(kids)
end

--- 一个字符串在终端里占几格（CJK 算两格）。
local function cells(s: string): number
	local n = 0
	for _, cp in utf8.codes(s) do
		n += if cp > 0x7E then 2 else 1
	end
	return n
end

--- 一个可点的按钮；keys 会画成键帽。
local function actionButton(spec: any): Node
	local node = ui.button(spec.text, { keys = spec.keys, variant = spec.variant, size = "sm" })
	local p: { [string]: any } = node.p or {}
	p.actions = { click = spec.act }
	node.p = p
	return node
end

--- 按钮的宽度估算：文案 + 键帽 + 内边距。估高一点比裁切安全。
local function buttonCells(spec: any): number
	local key = spec.keys[1] or ""
	-- 键帽里的方向键、车/退格等只占一格。
	local keyCells = if #key <= 2 then 1 else math.min(cells(key) + 1, 9)
	return cells(spec.text) + keyCells + 4
end

--- 把按钮按 pane 宽度折成好几排：窄了就多一排，不会被裁。
local function packRows(specs: { any }, cols: number): { { Node } }
	local out: { { Node } } = {}
	local row: { Node } = {}
	local used = 0
	local limit = math.max(16, cols - 4)
	for _, spec in ipairs(specs) do
		local w = buttonCells(spec)
		if #row > 0 and used + w > limit then
			table.insert(out, row)
			row = {}
			used = 0
		end
		table.insert(row, actionButton(spec))
		used += w
	end
	if #row > 0 then
		table.insert(out, row)
	end
	return out
end

local function primaryButtons(): { any }
	return {
		{ text = "插入", keys = { "Enter" }, variant = "primary", act = "insert" },
		{ text = "提交给 agent", keys = { "a" }, variant = "default", act = "submit" },
		{ text = "编辑", keys = { "e" }, variant = "default", act = "edit" },
		{ text = "复制为自定义", keys = { "c" }, variant = "default", act = "copy" },
		{ text = "新建", keys = { "n" }, variant = "default", act = "new" },
		{ text = "删除", keys = { "d" }, variant = "danger", act = "delete" },
	}
end

--- 第二组：有东西可撤回时最前面多一个撤回。
local function toolButtons(state: State): { any }
	local out: { any } = {}
	if state.trash then
		table.insert(out, { text = "撤回删除", keys = { "u" }, variant = "default", act = "undo" })
	end
	for _, spec in ipairs({
		{ text = "范围", keys = { "f" }, variant = "quiet", act = "scope" },
		{ text = "标签", keys = { "l" }, variant = "quiet", act = "label" },
		{ text = "搜索", keys = { "/" }, variant = "quiet", act = "search" },
		{ text = "预览", keys = { "Space" }, variant = "quiet", act = "preview" },
		{ text = "屏蔽", keys = { "h" }, variant = "quiet", act = "hide" },
		{ text = "全部屏蔽", keys = { "Shift+H" }, variant = "danger", act = "hideall" },
		{ text = "含已屏蔽", keys = { "v" }, variant = "quiet", act = "showhidden" },
		{ text = "同步命令", keys = { "r" }, variant = "quiet", act = "sync" },
		{ text = "重置次数", keys = { "Shift+R" }, variant = "danger", act = "reset" },
	}) do
		table.insert(out, spec)
	end
	return out
end

--- 把一组按钮按宽度铺成若干排。
local function rowsOf(specs: { any }, cols: number, out: { Node })
	for _, row in ipairs(packRows(specs, cols)) do
		table.insert(out, ui.row(row))
	end
end

local function dockView(state: State, cx: BlockCx): Node
	local rows: { Node } = {}
	if state.mode == "edit" then
		rowsOf({
			{ text = "保存", keys = { "Enter" }, variant = "primary", act = "save" },
			{ text = "取消", keys = { "Esc" }, variant = "quiet", act = "cancel" },
		}, cx.cols, rows)
		table.insert(rows, ui.text({ ui.span("Shift+Enter 正文换行 · Tab 切换字段", "dim") }))
		if state.message then
			table.insert(rows, ui.text({ ui.span(state.message, "warning") }))
		end
		return ui.col(rows)
	end

	rowsOf(primaryButtons(), cx.cols, rows)
	rowsOf(toolButtons(state), cx.cols, rows)
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

--- 一个动作，键与按钮共用同一套。
local function runAction(state: State, act: string, cx: BlockCx): boolean
	local t = selectedTemplate(state)
	if act == "insert" then
		if t then
			insertTemplate(state, t, cx)
		end
	elseif act == "submit" then
		if t then
			submitTemplate(state, t, cx)
		end
	elseif act == "edit" then
		if t and not t.builtin then
			openEditor(state, t.id)
		elseif t then
			state.message = "预制模板只读，可复制为自定义后编辑"
		end
	elseif act == "copy" then
		if t then
			copyToCustom(state, t)
		end
	elseif act == "new" then
		openEditor(state, nextCustomId(state))
	elseif act == "delete" then
		if t then
			deleteTemplate(state, t)
		end
	elseif act == "hide" then
		if t then
			toggleHidden(state, t)
		end
	elseif act == "hideall" then
		state.lib.hideAllPresets = not state.lib.hideAllPresets
		local changed, skipped = persist(state)
		local text = if state.lib.hideAllPresets then "已屏蔽全部预制模板" else "已恢复全部预制模板"
		state.message = withSync(text, changed, skipped)
	elseif act == "showhidden" then
		state.showHidden = not state.showHidden
	elseif act == "preview" then
		state.preview = not state.preview
	elseif act == "scope" then
		cycleScope(state)
	elseif act == "label" then
		cycleLabel(state)
	elseif act == "search" then
		state.mode = "search"
	elseif act == "sync" then
		local changed, skipped = persist(state)
		state.message = withSync("命令文件已同步", changed, skipped)
	elseif act == "undo" then
		undoDelete(state)
	elseif act == "reset" then
		resetUsage(state)
	else
		return false
	end
	return true
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
		runAction(state, "insert", cx)
	elseif key.name == "space" then
		runAction(state, "preview", cx)
	elseif k == "a" then
		runAction(state, "submit", cx)
	elseif k == "e" then
		runAction(state, "edit", cx)
	elseif k == "c" then
		runAction(state, "copy", cx)
	elseif k == "n" then
		runAction(state, "new", cx)
	elseif k == "d" then
		runAction(state, "delete", cx)
	elseif k == "h" then
		runAction(state, "hide", cx)
	elseif k == "H" then
		runAction(state, "hideall", cx)
	elseif k == "v" then
		runAction(state, "showhidden", cx)
	elseif k == "f" then
		runAction(state, "scope", cx)
	elseif k == "l" then
		runAction(state, "label", cx)
	elseif k == "r" then
		runAction(state, "sync", cx)
	elseif k == "R" then
		runAction(state, "reset", cx)
	elseif k == "u" then
		runAction(state, "undo", cx)
	elseif k == "/" then
		runAction(state, "search", cx)
	else
		return false
	end
	return true
end

--- 编辑态的保存；返回是否离开了编辑器。
local function commitDraft(state: State, draft: Draft): boolean
	local err = saveDraft(state, draft)
	if err then
		state.message = err
		return false
	end
	local changed, skipped = persist(state)
	state.message = withSync("已保存 " .. state.lib.custom[draft.id].name, changed, skipped)
	state.mode = "browse"
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
		if FIELDS[draft.at].key ~= "body" then
			draft.at = (draft.at % #FIELDS) + 1
		elseif key.shift then
			field.insert(f, "\n")
		else
			commitDraft(state, draft)
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
			preview = true,
			query = field.new(""),
			draft = nil,
			trash = nil,
			message = nil,
		}
		if type(saved) == "table" then
			state.scope = saved.scope :: templates.Scope
			state.label = saved.label
			state.showHidden = saved.showHidden == true
			state.preview = saved.preview ~= false
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
		return { main = main, dock = dockView(state, cx) }
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		if state.mode == "edit" then
			return editKey(state, key)
		end
		return browseKey(state, key, cx)
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx)
		if (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			local item = ev.item
			state.sel = if string.sub(item, 1, #LIST_ID) == LIST_ID then string.sub(item, #LIST_ID + 1) else item
			if ev.ev == "activate" then
				runAction(state, "insert", cx)
			end
			return
		end
		if ev.ev == "focus" and type(ev.id) == "string" then
			if ev.id == "main.f_query" then
				state.mode = "search"
			elseif state.mode == "edit" and state.draft then
				for i, f in ipairs(FIELDS) do
					if f.id == ev.id then
						state.draft.at = i
						return
					end
				end
			end
			return
		end
		if ev.ev ~= "action" then
			return
		end
		if state.mode == "edit" then
			if ev.act == "save" and state.draft then
				commitDraft(state, state.draft)
			elseif ev.act == "cancel" then
				state.draft = nil
				state.mode = "browse"
				state.message = nil
			end
			return
		end
		if type(ev.act) == "string" then
			runAction(state, ev.act, cx)
		end
	end,

	save = function(state: State): any
		return {
			scope = state.scope,
			label = state.label,
			showHidden = state.showHidden,
			preview = state.preview,
			sel = state.sel,
			query = state.query.text,
		}
	end,
})
