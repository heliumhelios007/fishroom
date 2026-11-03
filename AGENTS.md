# fishroom 维护入口

**先读**：`docs/PROJECT_HANDOFF.md` 的对应章节，不要每次重读全部历史报告。
**提交基线**：公开仓库 clone，不是 `D:\fishroom` 开发树。开发树含 logs/dist/个人配置，不是 git 仓库。

## 十条红线

1. 不把 DSH/QQ/memory 做成游戏内置；它们始终是玩家外部服务。
2. 不写死个人 QQ/群/玩家 ID、白名单、token、密钥、preset、人格卡、正式记忆。
3. 不重置存档来适配内容；新增内容必须增量合并并保留旧 ID。
4. 照片 ID 永不复用为另一张图；旧信不重新配图。
5. 不用本地模板伪造 AI 正文；DSH 不可用保持 pending。
6. 存档写入必须 `.tmp` + rename；失败保留旧档。
7. 旅行/信件只使用 `last_sim_time` 模拟时钟。
8. 鲸鱼娘角色/动作素材非商业，公开二创必须署名；不能按 MIT 重新授权。
9. 发布包不得包含 logs/docs 验收记录/tests/正式存档/连接配置/角色卡/记忆/开发 runtime。
10. 导出前 `project.godot` 的 autoload 只能有 `DisplayProfile`、`GameState`；`McpInteractionServer` 只允许编辑器调试动态加载，不能留在发布源码或包内。

## 开工前

- 只读 `docs/PROJECT_HANDOFF.md` 对应章节 + 本文。
- 备份正式档到 `%LOCALAPPDATA%\fishroom-backups\<task>-<timestamp>\`，记录 SHA256。
- 确认工作目录是公开仓库 clone；`D:\fishroom` 只用于本机运行/截图。

## 验证

- 脚本先跑 `godot_validate_script`。
- 跑引擎只用 `godot_*` 工具，绝不 shell 启动 Godot。
- 发布前 gate：
  1. 清掉 `McpInteractionServer`；
  2. 检查 autoload；
  3. 导出；
  4. 真实启动 EXE/APK；
  5. 检查包内无 logs/docs/tests/个人数据。
- 证据放 `logs/<task>/`；未执行不能写成通过。

## 回报模板

1. 改动清单（文件:行）
2. 验证证据（命令 + 结果 + 截图路径）
3. 未执行项及原因
4. 风险、回滚、对存档/旧档影响
5. 建议下一步

## 常用位置

- 交接：`docs/PROJECT_HANDOFF.md`
- 玩家 DSH/QQ：`docs/PLAYER_DSH_QQ_SETUP.md`
- 修改者：`docs/MODDING_GUIDE.md`
- Android 导出/审计：交接 §10
- Windows 导出：交接 §11
- 存档：`scripts/game_state.gd` + 交接 §4
- 旅行信：交接 §8
- 桌面布局：`scripts/display_profile.gd`、`scripts/ui/desktop_layout.gd`
