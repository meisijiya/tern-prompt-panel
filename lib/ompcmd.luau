--!strict
-- omp 命令文件：写到 ~/.omp/agent/commands/<name>.md，正文原样保留。
--
-- 目录解析与 omp 一致：PI_CODING_AGENT_DIR 优先，其次 <home>/<PI_CONFIG_DIR|.omp>[/profiles/<profile>]/agent。
-- 文件只在插件自己的清单里出现过时才删，避免动用户手写的同名文件。

local M = {}

--- 读环境变量；插件沙箱里取不到就当作没有。
local function env(name: string): string?
	local ok, value = pcall(tern.getenv, name)
	if ok and type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

function M.home(): string
	local home = env("HOME")
	if not home then
		home = env("USERPROFILE")
	end
	return home or ""
end

--- omp 用的用户级命令目录。
function M.commandsDir(): string
	local home = M.home()
	local configDir = env("PI_CONFIG_DIR") or ".omp"
	local profile = env("OMP_PROFILE") or env("PI_PROFILE")
	if profile == "default" then
		profile = nil
	end
	local base = home .. "/" .. configDir
	if profile then
		base = base .. "/profiles/" .. profile
	end
	local agentDir = base .. "/agent"
	local override = env("PI_CODING_AGENT_DIR")
	if override and not profile then
		agentDir = override
	end
	return agentDir .. "/commands"
end

--- frontmatter 的双引号字符串。
local function quote(s: string): string
	local escaped = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", " ")
	return '"' .. escaped .. '"'
end

--- 命令文件正文：frontmatter（description + argument-hint）加原样保留的正文。
function M.fileContent(description: string, argumentHint: string?, body: string): string
	local head = "---\ndescription: " .. quote(description) .. "\n"
	if argumentHint then
		head ..= "argument-hint: " .. quote(argumentHint) .. "\n"
	end
	head ..= "---\n\n"
	return head .. body .. "\n"
end

--- 写一个命令文件；目录不存在就建。
function M.write(dir: string, name: string, content: string): boolean
	pcall(tern.fs.mkdir, dir)
	local ok = pcall(tern.fs.write, dir .. "/" .. name .. ".md", content)
	return ok
end

--- 删一个命令文件（文件不存在也算成功）。
function M.remove(dir: string, name: string): boolean
	local path = dir .. "/" .. name .. ".md"
	if not tern.fs.exists(path) then
		return true
	end
	return (pcall(tern.fs.remove, path))
end

return M
