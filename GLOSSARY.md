# GLOSSARY

本项目的领域词汇。面板里出现的词，以这里定义的为准。

## Language

### Templates and labels

**Prompt Template**:
一段可复用的提示词文本，带名称、标签与绑定信息；面板管理的最小单位。
_Avoid_: 提示词、prompt、指令、词条

**Preset Template**:
随插件分发的一组 Prompt Template。只读、不可删除，但可以被整体屏蔽。
_Avoid_: 预制、preset、内置模板（裸词）、模板

**Custom Template**:
用户自建的 Prompt Template。可编辑、可删除。
_Avoid_: 自定义、custom、用户模板、模板

**Label**:
描述 Prompt Template 何时适用的统一语言，用于筛选与展示。
_Avoid_: tag、标签（当同义词泛用）、分类、领域、阶段、动作（作为独立筛选项）

**Derived Label**:
Preset Template 的 Label，由其领域、阶段、动作机械拼合而成。
_Avoid_: 派生标签（定义之外）、预制 tag

**Custom Label**:
Custom Template 的 Label，由用户挑选或自拟，最多三个。
_Avoid_: 自选标签（定义之外）、用户 tag

**Usage Count**:
Prompt Template 被插入或提交的累计次数，用于排序与展示。
_Avoid_: 用量、count（裸词）、热度

**Reset Usage**:
把全部 Usage Count 清零（面板里的 R），排序随之回到按名称。
_Avoid_: 清空统计、清零

**Template Library**:
Preset Template 与 Custom Template 组成的受管集合，连同标签、使用次数、屏蔽状态与绑定。
_Avoid_: store、storage、数据（裸词）

### Applying and hiding

**Insert**:
把 Prompt Template 的正文打进聚焦 omp agent 的输入框，同时复制到剪贴板。
_Avoid_: inject、paste、注入、粘贴、应用（当实现动词）

**Copy**:
把 Prompt Template 的正文复制到剪贴板。
_Avoid_: apply、应用

**Hide Presets**:
一个开关：让全部 Preset Template 退出面板展示与命令绑定。关闭时它们照常回来。
_Avoid_: 隐藏（当动作）、屏蔽列表

**Command Binding**:
Prompt Template 与一条 omp 斜杠命令的一一对应。有了它，模板可以在 omp 会话里直接以该命令名使用。
_Avoid_: command（裸词）、命令映射

**Sync**:
把面板里的 Prompt Template 与 Command Binding 写成 omp 侧的命令文件。
_Avoid_: export、导出

### Sorting

**Usage Ordering**:
列表按 Usage Count 降序，最常用的排在最上方；次数相同按名称。
_Avoid_: 倒序、底置（裸词）、reverse order

## Notes

- 词汇继承自 dsh-prompt（MIT）的领域模型，并按 tern 插件与 omp 的实际边界做了裁剪；裁掉的是远程触控层与智能推荐层。
