# AGENTS.md

## 插件

Tern 窗口插件。`host.luau` 是面板 block，`window.luau` 是命令与状态栏，`lib/` 放纯逻辑，
`presets/*.md` 是只读的预制模板；`tern.d.luau` 由 `tern plugin types .` 生成，勿手改。

- 测试：`test/build.sh [luau 路径]`。luau 的 require 在独立沙箱里跑，所以脚本把桩、`lib/`、
  两个半边拼成一个文件再执行；改了 `-- ==== MODULES ====` 两侧的结构要同步改它。
- 类型检查只有 luau-lsp 能读 `tern.d.luau`；`luau-analyze` 不支持定义文件。
- 真机验证：`tern plugin link .`、`tern plugin reload tern-prompt-panel`，再用 `tern ctl`
  驱动窗口（打开面板、按键、`shot`）看结果。

## Agent skills

### Issue tracker

Issues are tracked as GitHub issues in `meisijiya/tern-prompt-panel` via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles use the label names `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout: root `GLOSSARY.md` plus `docs/adr/`. See `docs/agents/domain.md`.
