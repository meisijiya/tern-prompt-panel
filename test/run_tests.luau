--!strict
-- 插件逻辑的测试：不需要 Tern 在跑。
--
--   luau test/run_tests.luau
--
-- tern 的 API 用内存桩顶替：kv 是一个表，fs 是一张路径表，预制模板是三个固定条目。
-- 桩只实现被测代码真正用到的那部分，多实现一处就可能把真机上的坑盖住。

-- ---------------------------------------------------------------- stub ----

local kvStore: { [string]: any } = {}
local fsFiles: { [string]: string } = {}
local fsDirs: { [string]: boolean } = {}
local env: { [string]: string } = { HOME = "C:/home" }
local toasts: { { level: string, text: string, sub: string? } } = {}
local copied: { string } = {}
local timers: { { ms: number, fn: (any) -> () } } = {}
local commands: { [string]: any } = {}
local statusFn: ((any) -> any)? = nil
local chromeRefreshes = 0
local handlers: { [string]: (any, any) -> any } = {}
local blockDefs: { [string]: any } = {}
local asked: { { pane: number, text: string } } = {}
local typed: { { pane: number, text: string } } = {}

local function copy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, val in pairs(v) do
		out[k] = copy(val)
	end
	return out
end

local function dirOf(path: string): string
	return string.match(path, "^(.*)/[^/]*$") or ""
end

local function baseOf(path: string): string
	return string.match(path, "([^/]*)$") or path
end

local ternStub = {
	kv = {
		get = function(key: string): any
			return copy(kvStore[key])
		end,
		set = function(key: string, value: any)
			kvStore[key] = copy(value)
		end,
	},
	fs = {
		exists = function(path: string): boolean
			return fsFiles[path] ~= nil or fsDirs[path] == true
		end,
		read = function(path: string): string
			local text = fsFiles[path]
			if text == nil then
				error("no such file: " .. path)
			end
			return text
		end,
		write = function(path: string, text: string)
			fsFiles[path] = text
			fsDirs[dirOf(path)] = true
		end,
		list = function(path: string): { string }
			local out = {}
			local prefix = path .. "/"
			for p in pairs(fsFiles) do
				if string.sub(p, 1, #prefix) == prefix and not string.find(string.sub(p, #prefix + 1), "/", 1, true) then
					table.insert(out, string.sub(p, #prefix + 1))
				end
			end
			table.sort(out)
			return out
		end,
		mkdir = function(path: string)
			fsDirs[path] = true
		end,
		remove = function(path: string)
			fsFiles[path] = nil
		end,
	},
	getenv = function(name: string): string?
		return env[name]
	end,
	now = function(): number
		return 0
	end,
	chrome = {
		status = function(fn: (any) -> any)
			statusFn = fn
		end,
		refresh = function()
			chromeRefreshes += 1
		end,
	},
	timer = function(ms: number, fn: (any) -> ())
		table.insert(timers, { ms = ms, fn = fn })
		return { cancel = function() end }
	end,
	command = function(def: any)
		commands[def.id] = def
	end,
	on = function(name: string, fn: (any, any) -> any)
		handlers[name] = fn
	end,
	block = {
		define = function(id: string, def: any)
			blockDefs[id] = def
		end,
	},
	ui = {
		span = function(t: string, s: string?): any
			return { t = t, s = s }
		end,
		text = function(spans: any): any
			return { k = "text", p = { spans = spans } }
		end,
		col = function(children: { any }): any
			return { k = "col", c = children }
		end,
		row = function(children: { any }): any
			return { k = "row", c = children }
		end,
		list = function(items: { any }): any
			return { k = "list", p = {}, c = items }
		end,
		badge = function(t: string, tone: string): any
			return { k = "badge", p = { t = t, tone = tone } }
		end,
		button = function(t: string?, props: any?): any
			local p: { [string]: any } = props or {}
			p.t = t
			return { k = "button", p = p }
		end,
		md = function(text: string): any
			return { k = "md", p = { text = text } }
		end,
		node = function(kind: string, props: any?): any
			return { k = kind, p = props or {} }
		end,
	},
}

-- 预制模板：catalog 从 "presets" 目录读它们。
local PRESETS = {
	["presets/alpha.md"] = "---\nid: alpha\nname: 阿尔法\nnameEn: Alpha\nlabels: 思考,决策\n---\n正文 A\n",
	["presets/beta.md"] = "---\nid: beta\nname: 贝塔\nlabels: 执行\n---\n正文 B\n",
	["presets/gamma.md"] = "---\nid: gamma\nname: 伽马\nlabels: 思考\n---\n正文 C\n",
}

-- 只清数据，不清注册：两个半边的注册在 bundle 加载时就完成了。
local function reset()
	kvStore = {}
	fsFiles = {}
	fsDirs = {}
	toasts = {}
	copied = {}
	timers = {}
	chromeRefreshes = 0
	asked = {}
	typed = {}
	for path, text in pairs(PRESETS) do
		fsFiles[path] = text
		fsDirs["presets"] = true
	end
end

reset()
tern = ternStub -- luau 的 _G 是只读的，全局赋值才行

-- ==== MODULES ====

-- window.luau 加载时排的第一拍轮询就是心跳本身；reset() 会清掉计时器队列。
local pollTick: any = timers[1] and timers[1].fn

-- -------------------------------------------------------------- runner ----

local passed, failed = 0, 0
local failures: { string } = {}

local function test(name: string, fn: () -> ())
	reset()
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
		table.insert(failures, name .. ": " .. tostring(err))
	end
end

local function eq(actual: any, expected: any, what: string?)
	local label = what or "value"
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
	end
end

--- 表里有几个键（字符串键的表不能用 # 数）。
local function count(t: { [any]: any }): number
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n
end

local function ok(cond: boolean, what: string)
	if not cond then
		error(what, 2)
	end
end

--- 一个按键。text 缺省时用 name。
local function key(name: string, text: string?, mods: { ctrl: boolean?, alt: boolean?, shift: boolean?, meta: boolean? }?): any
	local m = mods or {}
	return {
		name = name,
		text = if text ~= nil then text elseif #name == 1 then name else nil,
		ctrl = m.ctrl == true,
		alt = m.alt == true,
		shift = m.shift == true,
		meta = m.meta == true,
	}
end

-- ---------------------------------------------------------------- util ----

test("u16Len counts UTF-16 units", function()
	eq(util.u16Len("abc"), 3)
	eq(util.u16Len("中文"), 2)
	eq(util.u16Len("a😀b"), 4)
end)

test("insert16 inserts at a UTF-16 offset", function()
	local text, cursor = util.insert16("hello", 5, "!")
	eq(text, "hello!", "text")
	eq(cursor, 6, "cursor")
end)

test("insert16 lands after an astral character", function()
	local text, cursor = util.insert16("😀x", 2, "y")
	eq(text, "😀yx", "text")
	eq(cursor, 3, "cursor")
end)

test("backspace removes one code point, not one unit", function()
	local text, cursor = util.backspace("a😀", 3)
	eq(text, "a", "text")
	eq(cursor, 1, "cursor")
end)

test("deleteForward removes the character after the cursor", function()
	local text, cursor = util.deleteForward("a😀b", 1)
	eq(text, "ab", "text")
	eq(cursor, 1, "cursor")
end)

test("moveLeft and moveRight step over an astral character", function()
	eq(util.moveLeft("a😀", 3), 1, "left")
	eq(util.moveRight("a😀", 1), 3, "right")
end)

test("line moves stay inside the current line", function()
	local s = "one\ntwo\nthree"
	eq(util.lineStart16(s, 6), 4, "line start")
	eq(util.lineEnd16(s, 6), 7, "line end")
	eq(util.nextLine16(s, 2), 4, "next line")
	eq(util.prevLine16(s, 6), 3, "prev line")
end)

test("slug folds everything else into single dashes", function()
	eq(util.slug("Hello, World!"), "hello-world")
	eq(util.slug("中文"), "")
	eq(util.slug("a--b"), "a-b")
end)

test("stripCursor drops only the marker", function()
	eq(util.stripCursor("a{{cursor}}b"), "ab")
	eq(util.stripCursor("no marker"), "no marker")
end)

test("deepCopy does not share tables", function()
	local src = { list = { 1, 2 }, name = "x" }
	local out = util.deepCopy(src)
	out.list[1] = 9
	eq(src.list[1], 1, "source untouched")
	eq(out.list[1], 9, "copy changed")
end)

-- ----------------------------------------------------------- templates ----

test("parsePreset reads frontmatter and body", function()
	local t = templates.parsePreset(PRESETS["presets/alpha.md"])
	ok(t ~= nil, "parsed")
	eq(t.id, "alpha", "id")
	eq(t.name, "阿尔法", "name")
	eq(t.nameEn, "Alpha", "nameEn")
	eq(#t.labels, 2, "labels")
	eq(t.labels[1], "思考", "first label")
	eq(t.body, "正文 A", "body")
	eq(t.builtin, true, "builtin")
end)

test("parsePreset needs an id and a name", function()
	eq(templates.parsePreset("---\nname: 只有名字\n---\n正文"), nil)
	eq(templates.parsePreset("no frontmatter"), nil)
end)

test("commandName prefers the English name", function()
	local t = templates.parsePreset(PRESETS["presets/alpha.md"]) :: any
	eq(templates.commandName(t), "prompt-alpha")
end)

test("merge applies usage and hidden flags", function()
	local presets = catalog.load()
	local custom = { c1 = { id = "c1", name = "自建", labels = {}, body = "正文", command = "mine" } }
	local list = templates.merge(presets, custom, { alpha = 3, c1 = 1 }, { hideAllPresets = false, hidden = { beta = true } })
	eq(#list, 4, "count")
	local byId = {}
	for _, t in ipairs(list) do
		byId[t.id] = t
	end
	eq(byId.alpha.usage, 3, "preset usage")
	eq(byId.beta.hidden, true, "preset hidden")
	eq(byId.gamma.hidden, false, "preset visible")
	eq(byId.c1.builtin, false, "custom flag")
	eq(byId.c1.command, "mine", "custom command")
	eq(byId.c1.usage, 1, "custom usage")
end)

test("merge hides every preset with hideAllPresets", function()
	local list = templates.merge(catalog.load(), {}, {}, { hideAllPresets = true, hidden = {} })
	for _, t in ipairs(list) do
		eq(t.hidden, true, "hidden " .. t.id)
	end
end)

test("filter applies scope, label, query and hidden", function()
	local list = templates.merge(catalog.load(), {}, {}, { hideAllPresets = false, hidden = { beta = true } })
	local base = { scope = "all", label = nil, query = "", showHidden = false }
	eq(#templates.filter(list, base), 2, "hidden dropped")

	local withHidden = { scope = "all", label = nil, query = "", showHidden = true }
	eq(#templates.filter(list, withHidden), 3, "hidden kept")

	local presetsOnly = { scope = "preset", label = nil, query = "", showHidden = true }
	eq(#templates.filter(list, presetsOnly), 3, "presets")

	local customOnly = { scope = "custom", label = nil, query = "", showHidden = true }
	eq(#templates.filter(list, customOnly), 0, "no custom")

	local byLabel = { scope = "all", label = "思考", query = "", showHidden = true }
	local hits = templates.filter(list, byLabel)
	eq(#hits, 2, "label count")

	local byQuery = { scope = "all", label = nil, query = "ALPHA", showHidden = true }
	eq(#templates.filter(list, byQuery), 1, "query is case-insensitive")
end)

test("sort puts the most used first, then names", function()
	local list = templates.sort({
		{ id = "a", name = "b", nameEn = "b", labels = {}, body = "", builtin = true, usage = 1, hidden = false },
		{ id = "b", name = "a", nameEn = "a", labels = {}, body = "", builtin = true, usage = 1, hidden = false },
		{ id = "c", name = "c", nameEn = "c", labels = {}, body = "", builtin = true, usage = 5, hidden = false },
	})
	eq(list[1].id, "c", "most used")
	eq(list[2].id, "b", "alphabetical")
	eq(list[3].id, "a", "last")
end)

test("allLabels counts, then sorts by name", function()
	local list = templates.merge(catalog.load(), {}, {}, { hideAllPresets = false, hidden = {} })
	local labels = templates.allLabels(list)
	eq(labels[1], "思考", "most common")
	eq(#labels, 3, "distinct")
end)

-- ------------------------------------------------------------- library ----

test("read returns an empty library when kv raises", function()
	kvStore.library = nil
	tern.kv.get = function()
		error("half written")
	end
	local lib = library.read()
	tern.kv.get = function(key: string): any
		return copy(kvStore[key])
	end
	eq(#lib.custom, 0, "no custom")
	eq(lib.nextId, 1, "next id")
end)

test("read drops malformed entries instead of failing", function()
	kvStore.library = {
		custom = { bad = "nope", ok = { name = "好", labels = { "a", 2 }, body = "正文" } },
		usage = { alpha = "many", beta = 2 },
		hidden = { gamma = true },
		hideAllPresets = "yes",
		files = { alpha = "prompt-alpha" },
		nextId = 7,
		seq = 3,
	}
	local lib = library.read()
	eq(lib.custom.bad, nil, "bad custom dropped")
	eq(lib.custom.ok.labels[1], "a", "label kept")
	eq(lib.custom.ok.labels[2], nil, "non-string label dropped")
	eq(lib.usage.alpha, nil, "non-number usage dropped")
	eq(lib.usage.beta, 2, "usage kept")
	eq(lib.hidden.gamma, true, "hidden kept")
	eq(lib.hideAllPresets, false, "flag needs a boolean")
	eq(lib.files.alpha, "prompt-alpha", "files kept")
	eq(lib.nextId, 7, "next id")
	eq(lib.seq, 3, "seq")
end)

test("write then read round-trips the library", function()
	local lib = library.empty()
	lib.custom.c1 = { id = "c1", name = "自建", labels = { "x" }, body = "正文", command = "mine" }
	lib.usage.c1 = 4
	lib.hidden.alpha = true
	lib.hideAllPresets = true
	lib.files.c1 = "mine"
	lib.nextId = 2
	lib.seq = 9
	library.write(lib)

	local back = library.read()
	eq(back.custom.c1.name, "自建", "name")
	eq(back.custom.c1.command, "mine", "command")
	eq(back.usage.c1, 4, "usage")
	eq(back.hidden.alpha, true, "hidden")
	eq(back.hideAllPresets, true, "flag")
	eq(back.files.c1, "mine", "files")
	eq(back.nextId, 2, "next id")
	eq(back.seq, 9, "seq")
end)

test("validCommandName only takes a safe file name", function()
	eq(templates.validCommandName("prompt-a_1"), true)
	eq(templates.validCommandName("Prompt"), false)
	eq(templates.validCommandName("-x"), false)
	eq(templates.validCommandName("a b"), false)
end)

test("defaultCommand slugs the name", function()
	eq(templates.suggestCommand("MECE 拆解"), "prompt-mece")
	eq(templates.suggestCommand("中文"), "")
end)

-- ------------------------------------------------------------- ompcmd ----

test("commandsDir follows the omp environment", function()
	eq(ompcmd.commandsDir(), "C:/home/.omp/agent/commands")
	env.PI_CONFIG_DIR = ".config"
	eq(ompcmd.commandsDir(), "C:/home/.config/agent/commands")
	env.PI_CONFIG_DIR = nil
	env.OMP_PROFILE = "work"
	eq(ompcmd.commandsDir(), "C:/home/.omp/profiles/work/agent/commands")
	env.OMP_PROFILE = nil
	env.PI_CODING_AGENT_DIR = "D:/agent"
	eq(ompcmd.commandsDir(), "D:/agent/commands")
	env.PI_CODING_AGENT_DIR = nil
end)

test("fileContent writes a quoted description and keeps the body", function()
	local text = ompcmd.fileContent('say "hi"', nil, "正文\n第二行")
	ok(string.find(text, 'description: "say \\"hi\\""', 1, true) ~= nil, "description escaped")
	ok(string.find(text, "正文\n第二行", 1, true) ~= nil, "body kept")
end)

test("fileContent adds argument-hint only when given", function()
	local with = ompcmd.fileContent("d", "file", "b")
	local without = ompcmd.fileContent("d", nil, "b")
	ok(string.find(with, "argument-hint:", 1, true) ~= nil, "hint present")
	eq(string.find(without, "argument-hint:", 1, true), nil, "hint absent")
end)

-- ---------------------------------------------------------------- sync ----

local function merged(): { templates.Template }
	return library.templates(library.read())
end

test("sync writes one command file per visible template", function()
	local lib = library.empty()
	local changed = select(1, sync.sync(lib, merged()))
	eq(changed, true, "changed")
	eq(fsFiles["C:/home/.omp/agent/commands/prompt-alpha.md"] ~= nil, true, "alpha file")
	eq(fsFiles["C:/home/.omp/agent/commands/prompt-beta.md"] ~= nil, true, "beta file")
	eq(count(lib.files), 3, "files recorded")
end)

test("sync reports no change when files already match", function()
	local lib = library.empty()
	sync.sync(lib, merged())
	eq(select(1, sync.sync(lib, merged())), false, "second pass")
end)

test("sync removes the file of a hidden template", function()
	local lib = library.read()
	sync.sync(lib, merged())
	lib.hidden.alpha = true
	library.write(lib)

	local again = library.read()
	local changed = select(1, sync.sync(again, merged()))
	eq(changed, true, "changed")
	eq(fsFiles["C:/home/.omp/agent/commands/prompt-alpha.md"], nil, "file removed")
	eq(again.files.alpha, nil, "entry forgotten")
end)

test("sync removes the old file when a command is renamed", function()
	local lib = library.empty()
	lib.custom.c1 = { id = "c1", name = "自建", labels = {}, body = "正文", command = "old-name" }
	library.write(lib)

	local first = library.read()
	sync.sync(first, merged())
	eq(fsFiles["C:/home/.omp/agent/commands/old-name.md"] ~= nil, true, "old file written")

	first.custom.c1.command = "new-name"
	library.write(first)
	local second = library.read()
	eq(select(1, sync.sync(second, merged())), true, "changed")
	eq(fsFiles["C:/home/.omp/agent/commands/old-name.md"], nil, "old file removed")
	eq(fsFiles["C:/home/.omp/agent/commands/new-name.md"] ~= nil, true, "new file written")
end)

test("sync leaves files it never wrote alone", function()
	local lib = library.empty()
	fsFiles["C:/home/.omp/agent/commands/hand-written.md"] = "mine"
	sync.sync(lib, merged())
	eq(fsFiles["C:/home/.omp/agent/commands/hand-written.md"], "mine", "foreign file kept")
end)

test("sync skips a hand-written file that shares a template's command", function()
	local lib = library.empty()
	local path = "C:/home/.omp/agent/commands/prompt-alpha.md"
	fsFiles[path] = "手写的内容"
	local changed, skipped = sync.sync(lib, merged())
	eq(fsFiles[path], "手写的内容", "not overwritten")
	eq(skipped, 1, "reported")
	eq(lib.files.alpha, nil, "not claimed")
	eq(changed, true, "the other files still changed")
end)

-- ------------------------------------------------------------ host half ----

local hostDef: any = nil

local function hostCx(): any
	return {
		pane = 1,
		cols = 100,
		rows = 40,
		copy = function(_self: any, text: string)
			table.insert(copied, text)
		end,
		toast = function(_self: any, level: string, text: string, sub: string?)
			table.insert(toasts, { level = level, text = text, sub = sub })
		end,
		frame = function() end,
		render = function() end,
		save = function() end,
	}
end

local function loadHost()
	hostDef = blockDefs.prompts
	ok(hostDef ~= nil, "host registers the prompts block")
end

--- 把一个区域里的文字拼出来（text 取 spans，md 取原文）。
local function renderText(node: any?): string
	if type(node) ~= "table" then
		return ""
	end
	if node.k == "text" then
		local out = ""
		for _, part in ipairs(node.p.spans) do
			out ..= if type(part) == "string" then part else part.t
		end
		return out
	end
	if node.k == "md" then
		return node.p.text
	end
	local out = ""
	for _, child in ipairs(node.c or {}) do
		out ..= renderText(child)
	end
	return out
end

--- dock 里的按钮：文案、键帽、样式、动作。
local function dockButtons(state: any, cx: any): { any }
	local view = hostDef.view(state, cx)
	local out: { any } = {}
	local function walk(node: any)
		if type(node) ~= "table" then
			return
		end
		if node.k == "button" then
			table.insert(out, {
				text = node.p.t,
				keys = node.p.keys,
				variant = node.p.variant,
				act = node.p.actions and node.p.actions.click,
			})
		end
		for _, child in ipairs(node.c or {}) do
			walk(child)
		end
	end
	walk(view.dock)
	return out
end

test("host init syncs the command files and starts in browse", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	eq(state.mode, "browse", "mode")
	eq(fsFiles["C:/home/.omp/agent/commands/prompt-alpha.md"] ~= nil, true, "command file")
	eq(hostDef.title(state), "提示词面板 (3)", "title")
end)

test("enter inserts the selected template and counts the use", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	state.sel = "alpha"
	hostDef.key(state, key("enter"), cx)
	eq(copied[1], "正文 A", "copied body")
	eq(library.read().usage.alpha, 1, "usage counted")
	eq(kvStore.action.kind, "insert", "insert request")
	eq(kvStore.action.body, "正文 A", "body sent")
end)

test("j and k move the selection", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	state.sel = "gamma"
	hostDef.key(state, key("j"), cx)
	eq(state.sel, "beta", "moved down")
	hostDef.key(state, key("k"), cx)
	eq(state.sel, "gamma", "moved up")
end)

test("h hides the selected template and drops its command file", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	state.sel = "alpha"
	hostDef.key(state, key("h"), cx)
	eq(library.read().hidden.alpha, true, "hidden stored")
	eq(fsFiles["C:/home/.omp/agent/commands/prompt-alpha.md"], nil, "file removed")
end)

test("H hides every preset", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	hostDef.key(state, key("H", "H", { shift = true }), cx)
	eq(library.read().hideAllPresets, true, "flag stored")
	eq(count(fsFiles), 3, "only the preset sources remain")
end)

test("f cycles the scope and l cycles the label", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	hostDef.key(state, key("f"), cx)
	eq(state.scope, "preset", "preset scope")
	hostDef.key(state, key("f"), cx)
	eq(state.scope, "custom", "custom scope")
	hostDef.key(state, key("f"), cx)
	eq(state.scope, "all", "back to all")

	hostDef.key(state, key("l"), cx)
	eq(state.label, "思考", "first label")
	hostDef.key(state, key("l"), cx)
	ok(state.label ~= "思考", "moved on")
end)

test("slash searches and escape returns to the list", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	hostDef.key(state, key("/"), cx)
	eq(state.mode, "search", "search mode")
	hostDef.key(state, key("g", "g"), cx)
	hostDef.key(state, key("a", "a"), cx)
	eq(state.query.text, "ga", "query typed")
	hostDef.key(state, key("escape"), cx)
	eq(state.mode, "browse", "back to browse")
	eq(state.query.text, "ga", "query kept")
end)

test("n opens an empty editor and enter walks the fields", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	hostDef.key(state, key("n"), cx)
	eq(state.mode, "edit", "edit mode")
	eq(state.draft.at, 1, "starts on the name")
	hostDef.key(state, key("x", "x"), cx)
	eq(state.draft.name.text, "x", "typed into the name")
	hostDef.key(state, key("enter"), cx)
	eq(state.draft.at, 2, "moved to labels")
end)

test("saving a new template writes its command file", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	hostDef.key(state, key("n"), cx)
	hostDef.key(state, key("p", "p"), cx)
	hostDef.key(state, key("enter"), cx)
	hostDef.key(state, key("enter"), cx)
	hostDef.key(state, key("enter"), cx)
	hostDef.key(state, key("b", "b"), cx)
	hostDef.key(state, key("enter"), cx)
	eq(state.mode, "browse", "back to browse")
	local lib = library.read()
	eq(lib.custom.c1.name, "p", "saved name")
	eq(lib.custom.c1.command, "prompt-p", "default command")
	eq(fsFiles["C:/home/.omp/agent/commands/prompt-p.md"] ~= nil, true, "file written")
end)

test("shift+enter inserts a newline in the body", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	hostDef.key(state, key("n"), cx)
	hostDef.key(state, key("enter"), cx)
	hostDef.key(state, key("enter"), cx)
	hostDef.key(state, key("enter"), cx)
	hostDef.key(state, key("a", "a"), cx)
	hostDef.key(state, key("enter", nil, { shift = true }), cx)
	hostDef.key(state, key("b", "b"), cx)
	eq(state.draft.body.text, "a\nb", "newline kept")
	eq(state.mode, "edit", "still editing")
end)

test("save refuses an empty name, a long label list and a taken command", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)

	hostDef.key(state, key("n"), cx)
	hostDef.key(state, key("enter"), cx)
	hostDef.key(state, key("enter"), cx)
	hostDef.key(state, key("enter"), cx)
	hostDef.key(state, key("b", "b"), cx)
	hostDef.key(state, key("enter"), cx)
	eq(state.mode, "edit", "still editing")
	eq(state.message, "名称不能为空", "name message")

	hostDef.key(state, key("tab", nil, { shift = true }), cx)
	hostDef.key(state, key("tab", nil, { shift = true }), cx)
	hostDef.key(state, key("tab", nil, { shift = true }), cx)
	hostDef.key(state, key("p", "p"), cx)
	hostDef.key(state, key("enter"), cx)
	hostDef.key(state, key("a,b,c,d", "a,b,c,d"), cx)
	hostDef.key(state, key("enter"), cx)
	hostDef.key(state, key("enter"), cx)
	hostDef.key(state, key("enter"), cx)
	eq(state.message, "标签最多 3 个", "label message")
end)

test("e on a preset explains it is read-only", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	hostDef.key(state, key("e"), cx)
	eq(state.mode, "browse", "no editor")
	eq(state.message, "预制模板只读，可复制为自定义后编辑", "message")
end)

test("c copies a preset into an editable custom template", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	state.sel = "alpha"
	hostDef.key(state, key("c"), cx)
	eq(state.mode, "edit", "editor opened")
	eq(state.lib.custom.c1.name, "阿尔法", "copied name")
	eq(state.lib.custom.c1.body, "正文 A", "copied body")
end)

test("d deletes a custom template and its command file", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	hostDef.key(state, key("c"), cx)
	hostDef.key(state, key("escape"), cx)
	eq(state.mode, "browse", "back")
	hostDef.key(state, key("d"), cx)
	eq(#library.read().custom, 0, "custom dropped")
end)

test("clicking a row selects it, activating applies it", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	hostDef.event(state, { ev = "select", id = "main.items.", item = "main.items.beta" }, cx)
	eq(state.sel, "beta", "selected by click")
	hostDef.event(state, { ev = "activate", id = "main.items.", item = "main.items.beta" }, cx)
	eq(copied[1], "正文 B", "applied")
end)

test("a bare row id still selects the right row", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	hostDef.event(state, { ev = "select", id = "main.items.", item = "beta" }, cx)
	eq(state.sel, "beta", "bare id")
end)

test("clicking a field moves the editor to it", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	hostDef.key(state, key("n"), cx)
	hostDef.event(state, { ev = "focus", id = "main.f_body" }, cx)
	eq(state.draft.at, 4, "body field")
	hostDef.key(state, key("x", "x"), cx)
	eq(state.draft.body.text, "x", "typed into the body")
	eq(state.draft.name.text, "", "name untouched")
end)

test("a copy survives cancelling the editor", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	state.sel = "alpha"
	hostDef.key(state, key("c"), cx)
	hostDef.key(state, key("escape"), cx)
	eq(count(library.read().custom), 1, "copy stored")
end)

test("two copies of the same template get different commands", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	state.sel = "alpha"
	hostDef.key(state, key("c"), cx)
	hostDef.key(state, key("escape"), cx)
	hostDef.key(state, key("c"), cx)
	local lib = library.read()
	ok(lib.custom.c1.command ~= lib.custom.c2.command, "distinct commands")
	ok(fsFiles["C:/home/.omp/agent/commands/" .. lib.custom.c1.command .. ".md"] ~= nil, "first file")
	ok(fsFiles["C:/home/.omp/agent/commands/" .. lib.custom.c2.command .. ".md"] ~= nil, "second file")
end)

test("dock buttons run the same actions as the keys", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	state.sel = "alpha"
	hostDef.event(state, { ev = "action", act = "insert" }, cx)
	eq(copied[1], "正文 A", "inserted by button")
	hostDef.event(state, { ev = "action", act = "new" }, cx)
	eq(state.mode, "edit", "editor opened by button")
end)

test("the preview shows the selected body and space hides it", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	state.sel = "alpha"
	local view = hostDef.view(state, cx)
	ok(string.find(renderText(view.main), "正文 A", 1, true) ~= nil, "body previewed")

	hostDef.key(state, key("space"), cx)
	eq(state.preview, false, "preview off")
	local compact = hostDef.view(state, cx)
	ok(string.find(renderText(compact.main), "正文 A", 1, true) == nil, "body hidden")
end)

test("R resets every usage count", function()
	loadHost()
	local cx = hostCx()
	local lib = library.read()
	lib.usage.alpha = 4
	lib.usage.beta = 2
	library.write(lib)

	local state = hostDef.init(cx, {}, nil)
	hostDef.key(state, key("R", "R", { shift = true }), cx)
	eq(count(library.read().usage), 0, "counts cleared")
	ok(string.find(tostring(state.message), "已重置使用次数", 1, true) ~= nil, "message")
end)

test("every shortcut is a button that carries its key", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	local buttons = dockButtons(state, cx)
	ok(#buttons >= 10, "all actions are buttons")

	local byAct: { [string]: any } = {}
	for _, b in ipairs(buttons) do
		byAct[b.act] = b
	end
	eq(byAct.insert.keys[1], "Enter", "insert key")
	eq(byAct.insert.variant, "primary", "primary tone")
	eq(byAct.delete.variant, "danger", "delete tone")
	eq(byAct.hideall.keys[1], "Shift+H", "hide-all key")
	eq(byAct.reset.variant, "danger", "reset tone")
	eq(byAct.scope.variant, "quiet", "utility tone")
	eq(byAct.submit.keys[1], "a", "submit key")
	eq(byAct.reset.keys[1], "Shift+R", "reset key")
	eq(byAct.preview.keys[1], "Space", "preview key")
end)

test("the editor dock offers save and cancel", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	hostDef.key(state, key("n"), cx)
	local buttons = dockButtons(state, cx)
	local acts: { [string]: any } = {}
	for _, b in ipairs(buttons) do
		acts[b.act] = b
	end
	eq(acts.save.keys[1], "Enter", "save key")
	eq(acts.cancel.keys[1], "Esc", "cancel key")
end)

test("save returns the list state for the next start", function()
	loadHost()
	local cx = hostCx()
	local state = hostDef.init(cx, {}, nil)
	state.scope = "preset"
	state.label = "思考"
	state.showHidden = true
	state.sel = "beta"
	state.query = field.new("abc")
	local saved = hostDef.save(state)
	eq(saved.scope, "preset", "scope")
	eq(saved.label, "思考", "label")
	eq(saved.showHidden, true, "show hidden")
	eq(saved.sel, "beta", "selection")
	eq(saved.query, "abc", "query")

	local nextState = hostDef.init(cx, {}, saved)
	eq(nextState.scope, "preset", "restored scope")
	eq(nextState.query.text, "abc", "restored query")
end)

-- ---------------------------------------------------------- window half ----

local function windowCx(opts: any?): any
	local o = opts or {}
	local panes = o.panes or { { pane = 1, program = "shell" }, { pane = 2, program = "tern-prompt-panel.prompts" } }
	local agents = o.agents or {}
	local cx = {
		pane = 1,
		agents = {
			list = function(): { any }
				return agents
			end,
			ask = function(_self: any, pane: number, text: string)
				table.insert(asked, { pane = pane, text = text })
			end,
		},
		session = {
			panes = function(): { any }
				return panes
			end,
			focused = function(): number?
				return o.focused
			end,
			tab_of = function(): number?
				return o.tab
			end,
			layout = function(): any?
				return o.layout
			end,
		},
		layout = { focus = function() end },
		copy = function(_self: any, text: string)
			table.insert(copied, text)
		end,
		toast = function(_self: any, level: string, text: string, sub: string?)
			table.insert(toasts, { level = level, text = text, sub = sub })
		end,
		new_block = function(): number?
			return 2
		end,
		pick = function(): any
			return { next = function() end }
		end,
		run = function(_self: any, pane: number, text: string)
			table.insert(typed, { pane = pane, text = text })
		end,
	}
	return cx
end

local function loadWindow()
	ok(statusFn ~= nil, "window half registered")
end

--- 跑一拍轮询（poll 会自己续下一拍）。
local function pump(cx: any)
	ok(pollTick ~= nil, "the poll armed itself at load")
	pollTick(cx)
end

test("the status formatter reports the template count", function()
	loadWindow()
	ok(statusFn ~= nil, "status registered")
	local segments = statusFn({})
	eq(segments[1].text, "3 个模板", "count")
	eq(segments[1].command, "plugin.tern-prompt-panel.panel", "click opens the panel")
end)

test("the panel command always opens another panel", function()
	loadWindow()
	local opened = 0
	local cx = windowCx({ panes = { { pane = 1, program = "codex" } } })
	cx.new_block = function(): number?
		opened += 1
		return 2
	end
	commands.panel.run(cx)
	eq(opened, 1, "first panel")

	-- 已经有一个开着的面板，也要再开一个：一个 agent 旁边一个。
	local cx2 = windowCx({ panes = { { pane = 1, program = "codex" }, { pane = 2, block = "tern-prompt-panel.prompts" } } })
	cx2.new_block = function(): number?
		opened += 1
		return 3
	end
	commands.panel.run(cx2)
	eq(opened, 2, "second panel")
end)

test("an insert action types the body into the agent composer", function()
	loadWindow()
	kvStore.action = { seq = 80, kind = "insert", pane = 2, body = "正文 A", name = "阿尔法" }
	local cx = windowCx({ agents = { { pane = 9, state = "idle" } }, focused = 9 })
	handlers.focus({}, cx)
	pump(cx)
	eq(#typed, 1, "typed once")
	eq(typed[1].pane, 9, "into the agent pane")
	eq(typed[1].text, "正文 A", "body typed")
	eq(#asked, 0, "not submitted")
	eq(toasts[1].level, "success", "toast")
end)

test("a multi-line insert is wrapped as a bracketed paste", function()
	loadWindow()
	kvStore.action = { seq = 81, kind = "insert", pane = 2, body = "line1\nline2", name = "x" }
	local cx = windowCx({ agents = { { pane = 9, state = "idle" } }, focused = 9 })
	handlers.focus({}, cx)
	pump(cx)
	eq(typed[1].text, "\27[200~line1\nline2\27[201~", "wrapped")
end)

test("a panel sends to the agent beside it, not the focused one", function()
	loadWindow()
	kvStore.action = { seq = 82, kind = "insert", pane = 2, body = "x", name = "n" }
	local tree = { split = "right", [1] = { pane = 1 }, [2] = { pane = 2 } }
	local cx = windowCx({
		agents = { { pane = 1, state = "idle" }, { pane = 9, state = "idle" } },
		focused = 9,
		tab = 4,
		layout = { tab = 4, root = tree, floats = {}, zoomed = false, focus = 2 },
	})
	handlers.focus({}, cx)
	pump(cx)
	eq(#typed, 1, "typed once")
	eq(typed[1].pane, 1, "the neighbour, not the focused agent")
end)

test("two panels each target their own neighbour", function()
	loadWindow()
	local tree = {
		split = "right",
		[1] = { split = "down", [1] = { pane = 1 }, [2] = { pane = 2 } },
		[2] = { split = "down", [1] = { pane = 4 }, [2] = { pane = 3 } },
	}
	local layout = { tab = 4, root = tree, floats = {}, zoomed = false, focus = 2 }
	local agents = { { pane = 1, state = "idle" }, { pane = 4, state = "idle" } }

	kvStore.action = { seq = 83, kind = "insert", pane = 2, body = "a", name = "A" }
	local cx = windowCx({
		panes = { { pane = 1, program = "codex" }, { pane = 2, block = "tern-prompt-panel.prompts" } },
		agents = agents,
		focused = 1,
		tab = 4,
		layout = layout,
	})
	pump(cx)
	eq(typed[1].pane, 1, "left panel to the left agent")

	kvStore.action = { seq = 84, kind = "insert", pane = 3, body = "b", name = "B" }
	pump(cx)
	eq(typed[2].pane, 4, "right panel to the right agent")
end)

test("a panel alone in its tab falls back to the focused agent", function()
	loadWindow()
	kvStore.action = { seq = 85, kind = "insert", pane = 2, body = "x", name = "n" }
	local cx = windowCx({
		agents = { { pane = 9, state = "idle" } },
		focused = 9,
		tab = 4,
		layout = { tab = 4, root = { pane = 2 }, floats = {}, zoomed = false, focus = 2 },
	})
	handlers.focus({}, cx)
	pump(cx)
	eq(typed[1].pane, 9, "focused agent")
end)

test("a plugin pane is recognized by its block kind", function()
	loadWindow()
	kvStore.action = { seq = 90, kind = "submit", pane = 2, body = "正文 A" }
	local panes = {
		{ pane = 1, program = "shell" },
		{ pane = 2, kind = "plugin", block = "tern-prompt-panel.prompts" },
	}
	local cx = windowCx({ panes = panes, agents = { { pane = 9, state = "idle" } }, focused = 9 })
	handlers.focus({}, cx)
	pump(cx)
	eq(#asked, 1, "sent through the plugin pane")
end)

test("a submit action reaches the agent once per sequence", function()
	loadWindow()
	kvStore.action = { seq = 100, kind = "submit", pane = 2, body = "正文 A" }
	local agents = { { pane = 9, state = "idle" } }
	local cx = windowCx({ agents = agents, focused = 9 })
	handlers.focus({}, cx)
	pump(cx)
	eq(#asked, 1, "asked once")
	eq(asked[1].pane, 9, "target pane")
	eq(asked[1].text, "正文 A", "body sent")

	pump(cx)
	eq(#asked, 1, "same sequence not repeated")
end)

test("a stale sequence is ignored", function()
	loadWindow()
	kvStore.action = { seq = 200, kind = "submit", pane = 2, body = "先来" }
	local warm = windowCx({ agents = { { pane = 9, state = "idle" } }, focused = 9 })
	handlers.focus({}, warm)
	pump(warm)
	asked = {}

	kvStore.action = { seq = 150, kind = "submit", pane = 2, body = "旧" }
	local cx = windowCx({ agents = { { pane = 9, state = "idle" } }, focused = 9 })
	handlers.focus({}, cx)
	pump(cx)
	eq(#asked, 0, "nothing sent")
end)

test("a busy agent is not sent a prompt", function()
	loadWindow()
	kvStore.action = { seq = 300, kind = "submit", pane = 2, body = "正文" }
	local cx = windowCx({ agents = { { pane = 9, state = "working" } }, focused = 9 })
	handlers.focus({}, cx)
	pump(cx)
	eq(#asked, 0, "no ask")
	eq(toasts[1].level, "error", "toast")
end)

test("the poll keeps arming itself, panel or not", function()
	loadWindow()
	local closed = windowCx({ panes = { { pane = 1, program = "shell" } } })
	kvStore.action = { seq = 400, kind = "submit", pane = 2, body = "正文" }
	pump(closed)
	eq(#timers, 1, "re-armed")
	eq(#asked, 0, "nothing sent without the panel")
	eq(#toasts, 0, "no toast either")

	local open = windowCx({ agents = { { pane = 9, state = "idle" } }, focused = 9 })
	pump(open)
	eq(#asked, 1, "sent once the panel is there")
end)

test("quick insert lists visible templates only", function()
	loadWindow()
	local lib = library.read()
	lib.hidden.alpha = true
	library.write(lib)

	local captured: any = nil
	local cx = windowCx()
	cx.pick = function(_self: any, opts: any): any
		captured = opts
		return { next = function() end }
	end
	commands.insert.run(cx)
	eq(#captured.items, 2, "hidden template left out")
	eq(captured.items[1].label, "贝塔", "first visible")
end)

-- -------------------------------------------------------------- report ----

print(string.format("%d passed, %d failed", passed, failed))
for _, line in ipairs(failures) do
	print("  FAIL " .. line)
end
if failed > 0 then
	error(string.format("%d test(s) failed", failed), 0)
end
