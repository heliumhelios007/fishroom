# fishroom 项目交接与技术维护指南

面向准备改 UI、改存档、改旅行/信件、改 DSH 接入、改 Android/Windows 构建或大规模重构的维护者。

- 仓库：https://github.com/heliumhelios007/fishroom
- 引擎：Godot 4.7.2 stable
- 当前游戏版本：1.1.1
- 存档结构版本：1
- 内置内容版本：`base-1`
- 公开分支：`main`
- Android release：v1.1.1（修复 autoload 版）
- Windows release：v1.1.2（v1.1.1 的包内许可/文档分层修复版）

---

## 1. 先看结论：哪些东西不能随便动

1. **不要把游戏改成“内置 DSH/QQ/记忆”**。DSH、companion、memory、QQ bridge 都是玩家自己的外部服务；游戏只通过 HTTP 连接。
2. **不要在源码里写死个人 QQ 号、群号、玩家 ID、白名单、token、密钥、DSH preset、人格卡或正式记忆。**
3. **不要重置存档来适配新内容**。新增商品/旅行/照片必须是增量合并；旧 ID 的历史引用必须保留。
4. **照片 ID 永不复用为另一张图**。需要换图时用新 ID + 显式 alias；旧信不重新配图。
5. **不要用本地模板伪造 AI 正文**。DSH 不可用时保持 pending，不能写假旅行信或假日记。
6. **鲸鱼娘角色素材是非商业素材**。代码是 MIT，但角色美术不能按 MIT 重新授权；公开二创必须署名，禁止商用/付费/广告变现。
7. **存档写入必须保持原子性**：先写 `.tmp`，成功后 rename；失败保留旧档。
8. **旅行/信件时间必须使用同一个模拟时钟**。不要混用 `Time.get_unix_time_from_system()` 和 `last_sim_time`。
9. **桌面和手机是两个显示 profile，不是两份游戏**。业务状态、存档、DSH 接入共用。
10. **发布前必须清掉 `McpInteractionServer` autoload**。发布源码的 autoload 只能有 `DisplayProfile`、`GameState`；该脚本只允许编辑器调试时动态加载，不能进入 EXE/APK。
11. **发布包不能包含 logs、tests、docs 验收记录、个人存档、连接配置、角色卡、记忆或开发 runtime。**

---

## 2. 仓库与运行方式

### 2.1 公开仓库内容

公开仓库保留游戏运行源码：

```text
project.godot
export_presets.cfg
autoload/
scenes/
scripts/
assets/
data/
docs/
README.md
LICENSE
THIRD_PARTY_NOTICES.md
```

公开仓库**不包含**开发机的 `logs/`、`dist/`、`build/`、正式存档、DSH/QQ 配置、角色卡、正式记忆、`companion_core` 和 `integrations`。

### 2.2 运行

```text
Godot 4.7.2 → 导入 project.godot → F6/F5
```

空房子模式不需要 DSH、memory 或 QQ。角色默认显示；旅行中隐藏，旅行结束后恢复。

### 2.3 平台

- Android：竖屏，405×720 设计基准，`canvas_items` + `expand`
- Windows：1280×720 默认，16:9 全房间，桌面响应式 UI
- 启动时由 `DisplayProfile` 决定布局；Android 强制 MOBILE，不因横屏设备切桌面

---

## 3. 启动链路与场景树

### 3.1 启动链路

```text
project.godot
  main_scene = scenes/room/room.tscn
  autoload:
    DisplayProfile  (scripts/display_profile.gd)
    GameState       (scripts/game_state.gd)
    # McpInteractionServer 不是 autoload；仅编辑器调试由 room_view 动态加载

room.tscn
  Room (room_view.gd)
    Background
    FurnitureLayer (furniture_layer.gd)
    CharacterLayer
      WhaleGirl (whale_girl.gd)
    Camera2D
    UI/CanvasLayer
      Hint
      GameUI (scenes/ui/game_ui.tscn)
```

### 3.2 场景职责

| 节点/脚本 | 职责 |
| --- | --- |
| `scenes/room/room.tscn` | 房间背景、家具层、角色、相机、GameUI |
| `scenes/room/room_view.gd` | 相机取景、拖动、角色点击、开发工具动态加载 |
| `scripts/room/furniture_layer.gd` | 按 manifest 渲染家具；未知 ID 安全跳过 |
| `scenes/character/whale_girl.gd` | manifest 帧动画播放器、动作完成回 idle |
| `scenes/ui/game_ui.tscn` | 所有 HUD/面板/弹窗的节点容器 |
| `scripts/ui/game_ui.gd` | 业务 UI 与交互，约 2000 行；大部分功能入口在这里 |
| `scripts/ui/diary_panel.gd` | 日记/回忆/DSH 连接设置 |
| `scripts/display_profile.gd` | 平台/窗口/相机/面板尺寸策略 |
| `scripts/ui/desktop_layout.gd` | 桌面端重排现有 Control，不改业务逻辑 |

> `GameUI` 很大，但不要把业务逻辑复制到 `desktop_layout.gd`。桌面布局只负责位置和尺寸。

---

## 4. 存档系统（最高风险区）

### 4.1 路径

```text
user://save.json
```

Windows 通常在 `%APPDATA%/Godot/app_userdata/fishroom/save.json`；
Android 在应用私有目录 `files/save.json`。

### 4.2 结构

```json
{
  "version": 1,
  "currency": 120,
  "hunger": 100.0,
  "thirst": 100.0,
  "checkin": {"last_date":"","streak":0,"month":"","days":[]},
  "inventory": {"food":{}},
  "tickets": [],
  "owned_furniture": [],
  "last_sim_time": "2026-01-01T00:00:00+08:00",
  "alerted_hunger": false,
  "alerted_thirst": false,
  "chat_messages": [],
  "travel": {},
  "album": [],
  "content_version": "base-1",
  "content_archive": {},
  "food_lots": {},
  "pending_travels": []
}
```

### 4.3 字段含义

| 字段 | 说明 |
| --- | --- |
| `version` | 存档结构版本；当前 1 |
| `currency` | 鲸元券，非负整数 |
| `hunger/thirst` | 0–100，模拟推进 |
| `checkin.days` | 当前月签到日期 |
| `inventory.food` | 食物库存总数 |
| `tickets` | 已购车票；含 prepared_letters、catalog_snapshot、purchased_price 等 |
| `owned_furniture` | 已购家具稳定 ID |
| `last_sim_time` | 模拟时钟；旅行/信件/饥饿的唯一基准 |
| `chat_messages` | 聊天和旅行信 |
| `travel` | 当前旅行；结束前可能为空 |
| `pending_travels` | 回房后仍待补的旅行副本 |
| `album` | 相册 photo_id 列表 |
| `content_version` | 当前生效内容包版本 |
| `content_archive` | 旧照片/旧配置/历史引用快照 |
| `food_lots` | 历史食物数值批次 |
| `pending_travels` | 待补旅行副本，按票/索引去重 |

### 4.4 写入规则

`GameState.save_game()`：

1. 写 `save.json.tmp`
2. flush/close
3. `rename_absolute(tmp, save.json)`
4. 失败删除 tmp，保留旧档

任何新功能如果需要同时改多个结构，必须在**一次**保存里提交；中途失败要回滚内存。

### 4.5 迁移

- 当前 `SAVE_VERSION=1`；`load_game()` 对低版本只做已知字段读取，迁移占位在版本比较处。
- 新增结构版本时必须：
  - 增加 `SAVE_VERSION`
  - 写显式 `_migrate_vN_to_vM`
  - 迁移前备份原档
  - 不删除未知顶层字段（`_save_extras` 会往返保留）
- 不要用 `content_version` 代替 `version`。

### 4.6 导入/导出

`scripts/save_import_validator.gd` 负责类型、日期、唯一 ID、行程关系校验；`GameUI` 负责文件选择、覆盖提示。

导入不是“读 JSON 直接覆盖”：先校验，再备份，再应用。新增字段要同步更新 validator，否则合法新档可能被拒。

---

## 5. 数据与内容更新

### 5.1 内置 catalog

| 文件 | 入口 |
| --- | --- |
| `data/shop_food.json` | `items` |
| `data/shop_furniture.json` | `items` |
| `data/travel_locations.json` | `locations` |
| `assets/furniture/furniture_manifest.json` | `items`（房间渲染） |
| `data/checkin.json` | 签到 |
| `data/companion.json` | 本地默认地址（无个人密钥） |
| `data/economy.json` | 初始经济 |

### 5.2 内容包格式

ZIP 根目录直接放：

```text
content_manifest.json
data/*.json
assets/*
```

manifest 至少：

```json
{
  "content_version": "1.1.0",
  "min_game_version": "1.0.0",
  "files": ["data/shop_furniture.json"],
  "sha256": {"data/shop_furniture.json": "<64位小写sha256>"},
  "entrypoints": {"furniture": "data/shop_furniture.json"},
  "aliases": {"furniture": {"old_id": "new_id"}}
}
```

规则：

- 每版包是“相对 base-1 的累积覆盖”，不是依赖上一包的增量。
- 同 ID 覆盖未来 catalog；新 ID 追加；`deleted_ids` 下架。
- 已购商品/库存/车票/旅行/相册/信件/签到/余额不因下架删除。
- 未知 ID 安全归档；旧照片缺失显示占位。
- alias 只用于 food/furniture/locations；不推断相似名称。
- 内容包只允许数据、图片、音频、字体、受限静态 tscn；禁止脚本/可执行/链接/路径穿越。
- 每个包都有大小、条目、哈希上限；禁止同名覆盖已安装版本。
- 新内容包需要配套 runtime catalog 才能让电脑端生成新旅行信；APK 不负责同步 runtime。

### 5.3 内容包与存档的边界

- `save.json` 是唯一生效版本指针；`content_version` 必须和已安装目录匹配。
- 缺失当前内容版本时游戏会阻止写回，不要“重置存档解决”。
- 不要删除仍被正式档/备份引用的 `user://content/<version>/`。
- 旧旅行信照片 ID 不重新配到新图。

---

## 6. 桌面 / 手机显示

### 6.1 DisplayProfile

```text
MOBILE:
  405×720 设计
  canvas_items + expand
  camera cover
  左右拖动取景

DESKTOP:
  1280×720 默认，最小 960×540
  实际窗口像素
  camera fit：完整 1920×1080
  F11 / Alt+Enter 全屏，Esc 退全屏
```

`DisplayProfile` 只决定布局，不读写存档。

### 6.2 相机

`room_view.gd._fit_camera()`：

- 手机：`max(viewport/room)` cover，允许拖动
- 桌面：`min(viewport/room)` fit，显示全房间
- 窗口 resize 重新计算，不能把房间拖出边界

### 6.3 桌面 UI

`scripts/ui/desktop_layout.gd` 只重排现有控件：

- `PANEL_PATHS` 是面板节点路径；改节点名必须同步修改。
- 主面板限宽 620，最大高度窗口减去安全边距。
- 设置页使用 ScrollContainer；新增设置行要放进 settings body。
- 动作面板固定右侧，160 宽。
- 不要用整体 `scale` 缩放 UI；字体和按钮会失去清晰度。

### 6.4 手机布局

Android 继续走原 405×720 固定坐标；`desktop_layout` 不应在 MOBILE 下运行。改 UI 时每个新面板都要同时检查手机和桌面。

---

## 7. 角色与动作

### 7.1 来源与许可

鲸鱼娘帧动画来自：

```text
https://github.com/PC2005-cloud/dsh-pet
```

- 代码 MIT
- 角色素材：禁止商用；公开二创须署名
- 本仓库已转换的动作：idle/happy/tail/shy/angry/surprised/work_think/stretch/bubbles
- 不要把角色素材重新授权成 MIT

### 7.2 manifest

`assets/character/dsh_pet/character_manifest.json`：

```text
actions[action].frames[]   # 帧路径
actions[action].fps
actions[action].loop
actions[action].size
actions[action].anchor
```

`whale_girl.gd` 从 manifest 读取，不硬编码帧路径。新增动作：

1. 增加帧目录和 manifest 条目
2. 更新 `assets/character/dsh_pet/CREDITS.md`
3. 确认 `available_actions()` 包含它
4. 动作面板会自动列出；不需要改 `game_ui.gd`

### 7.3 动作面板

- 点击角色打开右侧面板
- 160 宽，三行可见，ScrollContainer
- 一次性动作完成后回 idle；循环动作保持
- 旅行中关闭/禁止打开
- 点击与房间拖动用 10px 位移阈值区分

---

## 8. 旅行、车票与旅行信

### 8.1 数据

`data/travel_locations.json`：

```json
{
  "locations": [{
    "id": "hangzhou",
    "name": "杭州",
    "photos": [{"id":"hz_westlake_santan","caption":"...","path":"..."}],
    "seats": [{
      "id": "business",
      "name": "商务座",
      "price": 256,
      "duration_hours": 12,
      "letters": [
        {"index":0,"hour":2,"photo_ids":["hz_westlake_santan"],"scene_prompt":"..."}
      ]
    }]
  }]
}
```

约束：

- `index` 从 0 连续
- `hour` 不超过 `duration_hours`
- `photo_ids` 只引用同地点照片
- 照片 ID 全局唯一，永不复用
- caption 是信件正文中必须逐字出现的文本

### 8.2 时间

- `last_sim_time` 是唯一模拟时钟
- `start_travel` 使用 `max(last_sim_time, wall_clock)`，不把调试时间回拨
- `ends_at = started_at + duration_hours`
- `scheduled_at = started_at + letter.hour`
- 调试推进复用 `advance_sim_to`，不能另起现实时间

### 8.3 信件生成链路

```text
购票/出发
  → GameState.get_letter_work()
  → CompanionClient._letter_payload()
  → POST /letters
  → LetterProvider.merge_ai()
  → prepared_letters / travel / pending
  → 到期投递到 chat_messages
```

关键点：

- 请求必须包含 location、seat、letter_count、letter_indices、plans、photos、generation_key
- 服务端返回 `{letters:[{index,title,body}]}`
- 空正文/`source=pending` 不投递
- 已有正文不重复生成
- 迟到响应要按 ticket_id + index 合并
- 生成失败保留 pending；回房后仍可补
- 稳定的 chat message ID 防重复
- 不要用本地模板补正文

### 8.4 常见故障

| 现象 | 优先检查 |
| --- | --- |
| 商务 +6h 就结束 | 是否混用了现实时间/模拟时间 |
| 0/3 且 pending 3 | `/letters` 是否返回 200；错误体/merge_reason |
| 一等/二等无信 | 正文长度、caption、虚构校验、超时 |
| 点不开信 | chat message 是否带 travel_letter 和 photo_ids |
| 旧信没图 | 照片 ID 是否被复用/内容包缺失；显示占位，不配新图 |
| 状态 400 | 看 error.code：INVALID_CAPTION/UNSAFE_FICTION/INVALID_LETTERS 等 |

---

## 9. DSH / QQ / memory 接入

### 9.1 架构

```text
Godot 游戏
  → CompanionClient（HTTP）
  → companion_core :8765
  → 用户自己的 DSH
  ↕
memory_service :8770
  ↕
QQ bridge（可选）
```

- 游戏不含 DSH/QQ/memory 本体
- 游戏不保存 DSH token
- 游戏不读玩家人格卡内容
- 三通道使用同一人格：
  - game：聊天/旅行信，无工具
  - diary：日记/回忆，无工具
  - QQ：玩家自己的桥接工具
- 手机不能填 `127.0.0.1` 访问电脑；用 LAN/Tailscale 私网网关

### 9.2 客户端接口

允许的 POST：

```text
/letters
/chat
/events
/connection
/connection/test
/connection/presets
```

GET：

```text
/connection
```

客户端特性：

- `HTTPRequest` 每次独立节点
- 信件硬超时 60 秒
- 失败保留 pending，30 秒后重试
- 收到响应检查 body_bytes、JSON、error.code
- 不打印完整正文/用户私密文本

### 9.3 玩家部署

详见 `docs/PLAYER_DSH_QQ_SETUP.md`。维护者不要把自己的 `connection.json`、preset、人格卡、memory 数据打包进仓库或 APK。

---

## 10. Android 构建

### 10.1 环境

- Godot 4.7.2
- JDK 17
- Godot Android export templates（含 android_debug.apk / android_release.apk）
- Android SDK（platform 35/36、build-tools）
- debug keystore

### 10.2 preset

```text
名称：Android Debug
包名：com.fishroom.game
竖屏
INTERNET / ACCESS_NETWORK_STATE
ABI：arm64-v8a + armeabi-v7a
非 Gradle 自定义构建
输出：dist/fishroom-debug.apk
```

### 10.3 导出

用 Godot 工具导出；不要让 shell 直接启动 Godot（Windows 沙箱会拦截 user:// 写入）。

```text
godot_export_project:
  preset = Android Debug
  debug = true
  output = dist/fishroom-debug.apk
```

### 10.4 审计

```powershell
py -3 tools/android_package.py --audit dist/fishroom-debug.apk
```

如果 Windows 的 `python` 是 Microsoft Store 存根、`py` 也不存在，本机开发直接用 DSH bundled Python：

```powershell
& 'C:\Users\heliu\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe' tools/android_package.py --audit dist/fishroom-debug.apk
```

公共机器没有该路径时安装 Python 3.10+ 或使用 `py -3`。审计脚本必须有可工作的解释器，否则发布流程视为阻塞，不能跳过。

> 公开仓库当前不包含 `tools/`；需要做内容包/APK 审计时，应在开发树使用完整工具，不要把审计产物提交到公开仓库。

检查：

- 无 logs/docs/tests/个人存档/connection/角色卡
- 无 MCP/DevPanel
- 7 张旅行图存在
- `aapt` 包名/竖屏/权限
- `apksigner` 签名
- `adb install -r` 真机空房子

### 10.5 发布

外层 ZIP 只放 APK + 玩家文档 + 修改者文档 + 许可/署名；文档不放进 APK。

---

## 11. Windows 构建

```text
preset：Windows Desktop
输出：dist/fishroom-windows/fishroom.exe
默认 1280×720
内嵌 PCK
release 不包含 DEV/调试面板
```

发布前：

1. 运行 `py -3 tools/windows_preset.py` 重新生成 Windows `export_files`（或使用本机 bundled Python）；确认它和 live `runtime_files()` 一致。
2. 运行 `godot_export_project`，输出 `fishroom.exe`。
3. 运行 `py -3 tools/windows_pck_audit.py <exe>`；它解析内嵌 PCK，检查 forbidden/unknown/debug、脚本/JSON/导入资源 1:1，并断言 preset 白名单不陈旧；失败不能发布。
4. 真实双击启动一次 EXE，检查 `%APPDATA%\Godot\app_userdata\fishroom\logs\godot.log` 无 autoload/资源错误。工具边界内不能启动 EXE 时，必须明确标记未执行。

发布 ZIP 结构（v1.1.2 起）：

```text
fishroom.exe
README.md
LICENSE
THIRD_PARTY_NOTICES.md
docs/PLAYER_DSH_QQ_SETUP.md
docs/MODDING_GUIDE.md
maintainer/PROJECT_HANDOFF.md
maintainer/AGENTS.md
maintainer/STAGE_STATUS.md
licenses/CHARACTER_CREDITS.md
```

- 玩家文档放 `docs/`，维护者文档放 `maintainer/`，不混在根目录。
- `LICENSE` 和 `THIRD_PARTY_NOTICES.md` 必须随二进制分发；README 里的链接必须指向包内真实文件。
- 自动云同步没有实现；Windows/Android 通过导出/导入迁移存档。

---

## 12. 常见改动 recipe

### 12.1 新增商品

1. 在 `data/shop_furniture.json` 或 `shop_food.json` 增加 item
2. 家具图标放 `assets/furniture/icons/`，房间渲染放 cutout 并更新 `furniture_manifest.json`
3. 图标尺寸/透明背景符合现有约定
4. 内容包场景则放 data + assets，生成 manifest
5. 测试旧档购买、已拥有、未知 ID

### 12.2 新增旅行地点

1. `data/travel_locations.json` 增加 location/seat/letters
2. 照片放 `assets/travel/<location>/`，7 张或按座位
3.  caption 必须和正文逐字匹配
4. 座位 index/hour 连续且不超过 duration
5. 内容包发布时 runtime catalog 要同步
6. 测试 +2/+6/+10/+12 和 pending

### 12.3 新增 UI 面板

1. 在 `game_ui.tscn` 建节点，业务逻辑放 `game_ui.gd`
2. 手机 405×720 坐标可用；桌面路径加入 `desktop_layout.gd` 的 `PANEL_PATHS`
3. 桌面限宽/居中/滚动
4. 关闭按钮/遮罩/ESC 行为
5. 手机 + 1280×720 + 1920×1080 截图

### 12.4 新增存档字段

1. 更新 `_state_to_dict` 和 `_apply_state`
2. 更新 `SAVE_VERSION` 和迁移
3. 更新 `save_import_validator.gd`
4. 确保未知字段往返保留
5. 用旧档/新档/损坏档测试
6. 不要强制 reset

### 12.5 改内容包逻辑

1. 只改 `content_manager.gd` 和 `game_state.gd` 的合并层
2. 保持 `content_version` 唯一指针
3. 保留 `content_archive`/`food_lots`/tickets 快照
4. 跑无效 ZIP/路径穿越/符号链接/校验和/回滚
5. 不要在内容包中放脚本

---

## 13. 测试清单

最低回归：

- 首次启动：空房子、120 鲸元券、无 DSH 可进商店/旅行/日记
- 角色：默认显示；旅行隐藏；九动作；动作面板
- 商店：买家具/食物/车票；余额/库存/相册
- 旅行：商务 12h/一等 8h/二等 4h；2/6/10 信；回房
- 信件：真实 DSH 200、pending、超时、重试、防重
- 日记：无 DSH pending；有 DSH 生成；不改人格
- 存档：导出/导入、旧档、旅行中档、内容包档
- 显示：手机竖屏、Windows 1280、1600、1920
- 内容包：新增/下架/alias/未知 ID/回滚
- 发布包：无个人数据/无调试入口

---

## 14. 已知限制 / 待办

- 自动云存档同步未实现；只有导出/导入。
- Android 当前是 debug 签名；正式商店发布需要 release keystore。
- Windows EXE 未代码签名，SmartScreen 可能提示。
- 外部 runtime/手机私网网关没有随包发布；需要发布者另行准备干净、可配置、受保护的 runtime。
- 新增旅行地点后，电脑端 companion 的 catalog 需要同步，否则生成可能 pending。
- 内容包实际文件选择/原子安装/重启恢复仍需真机/桌面完整验收。
- `GameUI` 体量大，未来建议按面板拆为独立脚本，但拆分前先补 UI 回归。
- 角色素材为非商业；任何商业化需先取得原作者授权或替换素材。

---

## 15. 提交/PR 检查

**提交基线是公开仓库 clone，不是 `D:\fishroom` 开发树。** 开发树的 logs/dist/个人配置不进入 PR。

- [ ] 没有个人 ID、QQ/群号、token、密钥、正式存档、记忆、角色卡
- [ ] `project.godot` autoload 只有 `DisplayProfile`、`GameState`
- [ ] 发布源码没有 `McpInteractionServer` autoload
- [ ] 没有把日志/验收记录/测试产物加入仓库
- [ ] 新增内容可被旧档安全读取
- [ ] 改动覆盖手机 + Windows
- [ ] 旅行/信件仍用模拟时钟
- [ ] pending 不被当成已投递
- [ ] 角色/素材署名保留
- [ ] 更新 README/文档
- [ ] 重新导出并审计发布包

---

## 16. 许可与署名

- 代码：MIT（`LICENSE`）
- 文档：CC BY 4.0
- 鲸鱼娘角色/动作：PC2005-cloud/dsh-pet，非商业，公开二创须署名
- 其它美术：由项目作者使用 AI 生成/提供
- 详见 `THIRD_PARTY_NOTICES.md` 和 `assets/character/dsh_pet/CREDITS.md`
