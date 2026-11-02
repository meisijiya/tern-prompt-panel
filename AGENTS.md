# AGENTS.md

## 插件

Tern 窗口插件。`host.luau` 是面板 block，`window.luau` 是命令与状态栏，`lib/` 放不碰 UI 的逻辑，
`presets/*.md` 是只读的预置模板；`tern.d.luau` 由 `tern plugin types .` 生成，勿手改。

- 测试：`test/build.sh [luau 路径]`。luau 的 require 在独立沙箱里跑，所以脚本把桩、`lib/`、
  两个半边拼成一个文件再执行；改了 `-- ==== MODULES ====` 两侧的结构要同步改它。
- 类型检查只有 luau-lsp 能读 `tern.d.luau`；`luau-analyze` 不支持定义文件。
- 真机验证：`tern plugin link .`、`tern plugin reload tern-prompt-panel`，再用 `tern ctl`
  驱动窗口（打开面板、按键、`shot`）看结果。改了 `lib/` 里的模块时，只 reload 会留着旧的
  require 缓存（新 `host.luau` 配旧 `lib/` 就是 `attempt to call a nil value`）：先
  `tern plugin unlink` 再 `link` 一次。

## 实现约束

写码前先过这四条；要违反任一条，先说明理由并征得同意，再动手：

- 入口只校验一次：外部数据在边界校验后转成内部类型，内部不再重复判断。
- 拒绝提前抽象：单处使用的逻辑就近内联，出现第三处重复才抽。
- 控制复杂度：能单函数说清就不拆，非必要不加 try/catch。
- 防御要有概率：低概率的边界/并发问题先报概率与代价，确认后才写；禁止为「理论上更稳」加代码。

这些是常驻纪律，所以住这里；面板里的 `presets/overdesign.md`、`presets/award.md` 只做一次性审计动作
（见 `docs/adr/0001-constraints-live-in-agents-md.md`）。

## Agent skills

### Issue tracker

Issues are tracked as GitHub issues in `meisijiya/tern-prompt-panel` via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles use the label names `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout: root `GLOSSARY.md` plus `docs/adr/`. See `docs/agents/domain.md`.
