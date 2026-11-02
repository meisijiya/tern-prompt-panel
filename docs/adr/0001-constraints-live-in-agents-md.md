# 常驻实现约束住 AGENTS.md，Preset Template 只装一次性动作

四条实现约束——入口单次校验、拒绝提前抽象、控制复杂度、防御要报概率——每次改码都要生效，
所以写进 `AGENTS.md` 由 agent 常态读取。Preset Template 只收一次性动作：审存量代码的
`presets/overdesign.md`、审界面的 `presets/award.md`。

放错位置的代价不对称：约束做成模板，要每次手动插入才生效，漏插就失效，且与「prompt 库」的
随手取用语义冲突；审计动作做成常驻规则，则每次改码都被触发一遍，噪声盖过信号。
