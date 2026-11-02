--!strict
-- 窗口半边：调色板命令、状态栏提示，以及把面板的"提交给 agent"请求转交给 omp。
--
-- 面板本身在宿主半边（host.luau）。两个半边不共享 Lua 状态，
-- 这里用 tern.kv 传令：宿主写 action 键，窗口轮询它并执行。
--
-- 只有宿主半边写库；窗口半边只读。

local library = require("./lib/library")
local templates = require("./lib/templates")
local util = require("./lib/util")

local KIND = "tern-prompt-panel.prompts"
local ACTION_KEY = "action"
local POLL_MS = 300

-- 最近聚焦的 omp agent：面板没有绑定目标时的兜底。
local lastAgent: number? = nil
-- 已经处理过的请求序号，避免重复提交。
local seenSeq = 0

--- 面板的全部模板（预置 + 自定义），与面板里看到的一致。
local function allTemplates(): { templates.Template }
	return library.templates(library.read())
end

-- 状态栏用的计数。加载时先算一次，首帧就是对的；之后由轮询更新。
local summary = { total = #allTemplates() }

--- 聚焦的 pane 是不是一个 omp agent。
local function agentPaneOf(cx: WindowCx): number?
	local focused = cx.session:focused()
	if not focused then
		return nil
	end
	for _, agent in ipairs(cx.agents:list()) do
		if agent.pane == focused then
			return agent.pane
		end
	end
	return nil
end

local function rememberAgent(cx: WindowCx)
	local pane = agentPaneOf(cx)
	if pane then
		lastAgent = pane
	end
end

--- 更新状态栏用的计数；变了就刷新 chrome。
local function refreshSummary()
	local total = #allTemplates()
	if total == summary.total then
		return
	end
	summary.total = total
	tern.chrome.refresh()
end

--- 这个 pane 是不是活着的面板块：窗口侧的块只在 block 里报插件 kind，program 只给终端/agent。
local function isPanel(pane: any): boolean
	if pane.exited ~= nil then
		return false
	end
	return pane.block == KIND or pane.program == KIND
end

--- 打开一个新面板：每个面板自己找旁边的 agent。
local function openPanel(cx: WindowCx)
	rememberAgent(cx)
	local pane = cx:new_block(KIND, nil, "beside")
	if pane == nil then
		cx:toast("error", "提示词面板没有加载", "把插件装在运行面板的机器上。")
	end
end

--- 多行正文包成括号粘贴：omp 的输入框会整段粘进去，不会在第一个换行处提交。
local function pasteText(body: string): string
	if string.find(body, "\n", 1, true) then
		return "\27[200~" .. body .. "\27[201~"
	end
	return body
end

--- 切分树里目标 pane 的同胞子树，由近到远；目标不在树里时返回 nil。
local function siblingsOf(tree: any, target: number): { any }?
	if type(tree) ~= "table" then
		return nil
	end
	if tree.pane == target then
		return {}
	end
	for i = 1, #tree do
		local inner = siblingsOf(tree[i], target)
		if inner then
			local out: { any } = {}
			for _, s in ipairs(inner) do
				table.insert(out, s)
			end
			for j = 1, #tree do
				if j ~= i and tree[j] then
					table.insert(out, tree[j])
				end
			end
			return out
		end
	end
	return nil
end

--- 一棵子树里的全部 pane，按树的顺序。
local function panesIn(tree: any, out: { number }): { number }
	if type(tree) ~= "table" then
		return out
	end
	if tree.pane then
		table.insert(out, tree.pane)
	end
	for i = 1, #tree do
		panesIn(tree[i], out)
	end
	return out
end

--- 面板自己旁边的 agent：同 tab 的切分树里离它最近的 agent 块。
local function agentFor(cx: WindowCx, panelPane: number): number?
	local tab = cx.session:tab_of(panelPane)
	local layout = if tab then cx.session:layout(tab) else nil
	if not layout then
		return nil
	end
	local agents: { [number]: boolean } = {}
	for _, a in ipairs(cx.agents:list()) do
		agents[a.pane] = true
	end
	for _, sub in ipairs(siblingsOf(layout.root, panelPane) or {}) do
		for _, id in ipairs(panesIn(sub, {})) do
			if agents[id] then
				return id
			end
		end
	end
	return nil
end

--- 把正文发给某个 omp agent。出错时返回错误说明。
local function sendToAgent(cx: WindowCx, pane: number, body: string): string?
	for _, agent in ipairs(cx.agents:list()) do
		if agent.pane == pane then
			if agent.state == "working" then
				return "agent 正在忙，等它空闲再试"
			end
			if agent.delivery_error then
				return tostring(agent.delivery_error)
			end
			local ok, err = pcall(function()
				cx.agents:ask(pane, body)
			end)
			if not ok then
				return tostring(err)
			end
			return nil
		end
	end
	return "找不到那个 agent"
end

--- 快速插入：挑一个模板，复制正文并发给聚焦的 omp agent。
local function quickInsert(cx: WindowCx)
	local items: { any } = {}
	for _, t in ipairs(allTemplates()) do
		if not t.hidden then
			table.insert(items, {
				label = t.name,
				detail = table.concat(t.labels, " · "),
				group = if t.builtin then "预置模板" else "自定义模板",
				body = util.stripCursor(t.body),
				name = t.name,
			})
		end
	end
	if #items == 0 then
		cx:toast("info", "没有可用的模板")
		return
	end
	cx:pick({ placeholder = "插入提示词", icon = "prompt", items = items }):next(function(item, _err, cx)
		if not item or not cx then
			return
		end
		cx:copy(item.body)
		local agent = lastAgent or agentPaneOf(cx)
		if not agent then
			cx:toast("info", "已复制：" .. item.name, "没有聚焦的 omp agent")
			return
		end
		local err = sendToAgent(cx, agent, item.body)
		if err then
			cx:toast("error", "提交失败：" .. item.name, err)
			return
		end
		cx:toast("success", "已提交：" .. item.name)
	end)
end

--- 执行宿主半边请求的动作：insert 打进输入框，submit 直接提交。
local function handleAction(cx: WindowCx)
	local ok, action = pcall(tern.kv.get, ACTION_KEY)
	if not ok or type(action) ~= "table" then
		return
	end
	local seq = action.seq
	if type(seq) ~= "number" or seq <= seenSeq then
		return
	end
	seenSeq = seq
	if type(action.body) ~= "string" then
		return
	end
	local pane = if type(action.pane) == "number" then action.pane else nil
	local agent = (if pane then agentFor(cx, pane) else nil) or lastAgent or agentPaneOf(cx)
	if not agent then
		cx:toast("info", "没有聚焦的 omp agent", "正文已复制，可以直接粘贴。")
		return
	end
	if action.kind == "insert" then
		local ok2 = pcall(function()
			cx:run(agent, pasteText(action.body))
		end)
		if ok2 then
			cx:toast("success", "已插入：" .. tostring(action.name))
		else
			cx:toast("error", "插入失败", "正文已复制，可以直接粘贴。")
		end
		return
	end
	if action.kind ~= "submit" then
		return
	end
	local err = sendToAgent(cx, agent, action.body)
	if err then
		cx:toast("error", "提交失败", err)
	end
end

--- 面板开着的时候才干活。
local function panelOpen(cx: WindowCx): boolean
	for _, pane in ipairs(cx.session:panes()) do
		if isPanel(pane) then
			return true
		end
	end
	return false
end

local poll: (WindowCx?) -> ()

poll = function(cx)
	if cx and panelOpen(cx) then
		handleAction(cx)
		refreshSummary()
	end
	tern.timer(POLL_MS, poll)
end

tern.command({
	id = "panel",
	title = "提示词面板",
	icon = "prompt",
	run = openPanel,
})

tern.command({
	id = "insert",
	title = "快速插入提示词",
	icon = "sparkle",
	run = quickInsert,
})

tern.chrome.status(function(_pane)
	return {
		{ text = tostring(summary.total) .. " 个模板", icon = "prompt", command = "plugin.tern-prompt-panel.panel" },
	}
end)

tern.on("focus", function(_ev, cx)
	rememberAgent(cx)
end)

-- 窗口重启后第一次看到的请求当作已处理，避免重复提交。
do
	local ok, action = pcall(tern.kv.get, ACTION_KEY)
	if ok and type(action) == "table" and type(action.seq) == "number" then
		seenSeq = action.seq
	end
end

-- 轮询从加载就开始：面板可以随时打开（也可能已经开着）。
tern.timer(POLL_MS, poll)

