# fishroom

一个使用 **Godot 4.7.2** 制作的桌面/Android 小鲸鱼陪伴房间。

游戏本体只负责房间、角色、商店、旅行、日记和本地存档；聊天、旅行信和日记的 AI 生成由玩家自己的 **DSH / companion / memory** 服务提供。没有连接外部服务时，游戏会以空房子模式启动，角色仍然可以互动。

## 功能

- 初音岛风格的 1920×1080 房间与竖屏手机取景
- 鲸鱼娘 idle、开心、摇尾巴、害羞、生气、惊讶、思考、伸懒腰、吐泡泡九套动作
- 商店、背包、家具、食物、车票
- 杭州旅行：商务座 / 一等座 / 二等座，旅行照片和旅行信
- 每日回忆式日记
- 导入/导出存档
- 用户自己的 DSH 聊天、QQ 统一人格与记忆（外部服务）
- 可选内容包：商店商品、旅行地点等数据更新，保留旧存档

## 快速开始

1. 用 Godot 4.7.2 打开本目录的 `project.godot`。
2. 直接运行即可进入空房子模式。
3. 想接入 AI：
   - 阅读 [玩家指南：DSH / QQ 接入](docs/PLAYER_DSH_QQ_SETUP.md)
   - 启动你自己的 DSH、companion 和 memory 服务
   - 在游戏设置里填写服务地址与 preset

Android 构建配置在 `export_presets.cfg`；Android 包不包含 DSH、QQ bridge 或 memory 服务。

## Windows 桌面版

- 默认 1280×720，可调整窗口并支持全屏
- 相机显示完整 1920×1080 房间，不再使用手机竖屏裁切
- 桌面 UI 使用限宽/居中布局；手机端保持原竖屏布局
- Windows 与 Android 共用同一份存档格式，可用导出/导入在两端迁移
- 构建 preset：`Windows Desktop`，输出 `dist/fishroom-windows/fishroom.exe`

## 文档

- [玩家 DSH / QQ 接入](docs/PLAYER_DSH_QQ_SETUP.md)
- [修改者指南](docs/MODDING_GUIDE.md)
- [项目交接与技术维护指南](docs/PROJECT_HANDOFF.md)

## 素材与署名

- 鲸鱼娘形象与动作帧来自 **PC2005-cloud/dsh-pet**：
  https://github.com/PC2005-cloud/dsh-pet
  - 代码许可：MIT
  - **素材许可：禁止商用；公开渠道二创须署名**
  - 转换后的动作帧保留了来源说明，详见 `assets/character/dsh_pet/CREDITS.md`
- 除鲸鱼娘角色帧动画外，项目内其余美术素材由项目作者使用 AI 生成或提供。
- 本项目为**非商业开源项目**；禁止将鲸鱼娘素材用于付费、广告变现或商业产品。
- 详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 许可

- 代码：MIT，见 `LICENSE`
- 文档：CC BY 4.0
- 角色素材：遵循 dsh-pet 原作者的素材许可，不使用 MIT 重新授权

## 注意

- 不要提交个人存档、`connection.json`、DSH/QQ 配置、token、密钥或私人记忆。
- 手机不能直接用 `127.0.0.1` 访问电脑上的服务，请使用局域网/Tailscale 地址。
- 当前仓库不包含开发者个人存档、记忆、角色卡或 QQ 白名单。
