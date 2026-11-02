# fishroom 修改者指南（Android）

## 目录与修改位置

| 路径 | 用途 |
| --- | --- |
| `project.godot` | 入口、405×720 竖屏、540×960 预览、GameState autoload |
| `scenes/room/room.tscn`、`room_view.gd` | 房间、相机、角色显示；无 DSH 时空房子 |
| `scripts/room/furniture_layer.gd` | 家具 manifest 渲染与安全跳过未知 ID |
| `scenes/ui/game_ui.tscn`、`scripts/ui/game_ui.gd` | 商店、背包、旅行、相册、设置 |
| `scripts/ui/diary_panel.gd` | 外部记忆/日记及 DSH preset 设置 |
| `assets/ui/theme/game_theme.tres`、`assets/fonts/` | 主题和中文字体 |
| `data/shop_furniture.json`、`shop_food.json` | 商品 catalog |
| `data/travel_locations.json` | 地点、座位、照片和信件排期 |
| `assets/furniture/furniture_manifest.json` | 家具透明图、渲染偏移；与商品 ID 对应 |
| `scripts/content_manager.gd` | 内容包校验、白名单、安装与 alias 解析 |
| `scripts/game_state.gd`、`save_import_validator.gd` | 存档、事务、历史引用兼容 |
| `tools/android_package.py` | 生成 Android 白名单与审计 APK/PCK；不启动 Godot |
| `tests/content_update_test.gd` | 隔离内容合并和回滚回归 |

修改 UI/脚本属于游戏版本更新，必须重新导出 APK。内容包只用于数据与静态素材。不要借更新内容重做家具、车票或食物玩法。

## 商品数据

家具入口 `{"items":[...]}`，每条包含：

```json
{"id":"mod_painting_sea","name":"海景挂画","price":30,"category":"挂画","description":"一幅海景。","order":20,"icon":"assets/icons/sea.png"}
```

`id` 是稳定主键；价格为非负安全整数，本内容包校验上限为十亿。`order` 控制显示顺序。新增家具图标建议 256×256，保持透明背景和内容留白；现有图标尺寸不完全相同，界面按比例显示。房间 source 使用 1920×1080 透明画布，`render_offset_y` 沿用家具 manifest 语义。新增可摆放家具需同时提供 `furniture_render` 入口，不能只添加商品图标。

食物入口同样为 `items`：

```json
{"id":"mod_snack","name":"点心","category":"主食","price":3,"hunger":8,"thirst":0,"icon":"assets/food/snack.png"}
```

食物图标使用 256×320（4:5），透明底或遵循现有素材风格。类别沿用 `主食`、`饮品`、`水果`；hunger/thirst 是 0–100 非负整数，价格只影响购买。不要把描述或 scene_prompt 当成可执行指令。内容包不修改全局模拟速度、签到或经济算法。

已有库存首次更新时冻结为 `food_lots` 数值快照；之后新购买记录使用当前 catalog 数值，使用时按购买批次消耗。库存总数字段保持原结构。既有车票的地点配置、信件排期与价格记录也保留快照；更新不回写旧票价格或已生成正文。旧档没有记录的历史购买价格不能凭空恢复。

## 旅行地点、座位与照片

地点入口 `{"locations":[...]}`。以下展示结构，图片须真实存在：

```json
{
  "locations": [{
    "id":"mod_lake", "name":"湖畔", "origin":"鱼缸",
    "ticket_art_crop":"assets/tickets/lake.png",
    "photos":[{"id":"mod_lake_morning","caption":"晨光落在湖面上","path":"assets/travel/lake_morning.png","status":"ready"}],
    "seats":[{"id":"second","name":"二等座","price":36,"duration_hours":4,"photo_count":1,
      "letters":[{"index":0,"hour":2,"photo_ids":["mod_lake_morning"],"scene_prompt":"清晨、湖水、安静的心情。","route_note":"按给定照片写沿途感受。"}]}]
  }]
}
```

照片建议 1600×900 或其它 16:9 尺寸。caption 是照片描述，scene_prompt/route_note 只提供与照片一致的情景素材。虚构插画要明确标注虚构，不得暗示真实合影或公司内部事实。座位 `index` 从 0 连续编号；`hour` 是出发后的小时数，不能超过 duration_hours；photo_ids 必须引用同一地点实际照片。现有 content 校验支持最长 8760 小时的行程。

**照片 ID 永不复用为另一张图，不做照片 alias。** 地点或座位改名时保留 ID；确实需要新 ID 时使用显式 alias。旧旅行只接受其存档中的照片 ID，缺图显示占位。相册当前沿用全局 photo_id 去重，因此新增照片 ID 应在所有地点中唯一。

客户端可以加载新增地点；现有电脑 companion 的生成校验仍读取电脑上的 catalog。发布新增旅行内容时，需由玩家在自己的配套 runtime 同步受信任的数据，重启 runtime 后再生成信件；否则生成请求可能保持 pending。APK 不修改玩家的 runtime 或 QQ 配置。

## 内容包格式

ZIP 根目录直接放 `content_manifest.json`、`data/*.json` 和 `assets/*`，不要再套一层目录。manifest 示例：

```json
{
  "content_version":"1.1.0",
  "min_game_version":"1.0.0",
  "files":["data/shop_furniture.json","assets/icons/sea.png"],
  "sha256":{
    "data/shop_furniture.json":"填写该文件原始字节的64位小写SHA256",
    "assets/icons/sea.png":"填写该文件原始字节的64位小写SHA256"
  },
  "entrypoints":{"furniture":"data/shop_furniture.json"},
  "aliases":{"furniture":{"old_sea_painting":"mod_painting_sea"}}
}
```

哈希不包含 manifest 自身；清单必须与 ZIP 所有其它文件精确对应。可用入口为 `food`、`furniture`、`locations`、`furniture_render`，对应 items/items/locations/items。兼容 `migration_map` 作为 aliases 的替代字段，二者不要混用。alias 只支持 food/furniture/locations，拒绝循环或不存在的目标；不改写存档原始 ID，不推断相似名称。

允许 JSON、PNG/JPEG/WebP、WAV/OGG/MP3、TTF/OTF、严格受限的静态 `.tscn`。不接受 GD/CS、二进制资源、GDExtension、可执行文件、SVG 或通用 `.tres`。场景仅允许静态视觉节点/资源，不允许脚本、连接、实例场景、UID 或未知资源类型；场景不自动实例化。更新 UI 和逻辑仍需 APK 更新。

素材路径用 `assets/...` 表示包内文件，安装时改写到 `user://content/<version>/assets/...`；`res://assets/...` 仅能引用已存在的内置资源。JSON 不能引用脚本或任意 user://、网络、绝对路径。ZIP 拒绝 `../`、反斜杠、盘符、隐藏段、绝对路径、重复/大小写冲突路径、符号链接、设备、加密、分卷和 ZIP64。单包压缩上限 128 MiB、展开总量 256 MiB、单文件 32 MiB、最多 1024 个条目；压缩工具应省略目录条目。

SHA256 用于完整性校验，不提供发布者签名；玩家仍应只安装可信来源内容。

在独立内容源目录制作 JSON 与素材，然后执行：

```powershell
python tools/content_pack.py path/to/content-source dist/example-content.zip --version 1.1.0
```

构建器自动生成 files/sha256/entrypoints；源目录可选 manifest 只读取 min_game_version 和 aliases/migration_map。构建器不是游戏校验器，导入测试仍需实际运行。

## 合并和提交

每一版包都是**针对内置基础内容的累积覆盖包**，不是针对上一包的增量补丁。升级版必须包含希望继续存在的旧扩展条目，并在本版提供完整 alias；不依赖玩家安装顺序。

同 ID 条目覆盖未来 catalog；新 ID 追加；入口文件可用 `deleted_ids:["old_id"]` 下架条目。未指定入口保留内置基础 catalog。删除不能与本文件新增/覆盖同一 ID 同时发生。下架不触碰 owned_furniture、库存总数、tickets、travel、pending_travels、album、chat_messages、checkin 或 currency；未知引用保留、显示归档或安全占位，不退款、不清空。

导入顺序：精确备份当前 save.json → ZIP/manifest/hash/数据校验 → 写入独立 staging → 原子重命名为内容版本目录 → 冻结旧内容引用与已购物品数据 → 用同一次原子存档保存 content_version → 发信号刷新房间/商店/旅行/相册。save.json 是唯一生效版本指针，没有第二个需要同步的 active 文件。

校验或写入失败不切换内容；存档提交失败回滚内存且保留原档。崩溃发生在内容写完但存档提交前，仅留下未启用的目录。已安装版本不可覆盖，以新版本号重试；失败的 staging 和未启用目录不会自动启用。不要删除仍被正式档或备份引用的版本。启动时重新校验已安装 ZIP 及素材字节；对应包丢失/损坏时使用基础内容显示并禁止写回，等待恢复原内容。

## 存档与不可修改边界

`version=1` 是结构版本，`content_version` 是内容版本，二者不能混为一谈。兼容增加 `content_archive`（旧照片/配置）、`food_lots`（已购数值批次）、车票 `catalog_snapshot` 与 `purchased_price`。未知顶层字段可往返保留，未来迁移仍需显式实现。旧档没有新字段时按原数据读取，内容更新前再补快照。

导入存档验证字段类型、日期、唯一 ID 和行程关系，不因 catalog 缺少 ID 而拒绝整个档。内容包不接受 save.json，也不调用重置/导入正式档。历史信件正文不用于重建人格。

不要修改玩家 DSH/QQ 的 connection.json、账号配置、人格卡、正式记忆、群权限、会话映射或主人身份。不要更改内置已有商品、座位和照片的硬编码 ID 来表示不同对象；确需迁移先设计 alias/兼容逻辑。开发环境的个人配置与旧验收资料不能作为发布模板。美术署名与许可须在发布外层的许可文件中保留；角色素材的非商业限制需由发布者遵守。

## 测试与 Android 导出

1. 先备份正式存档并记录 SHA256。运行 `python tools/prepare_content_tests.py` 创建 `build/android-content-tests`；它使用独立应用名和 user 目录，无调试或 GameState autoload。只通过可用 Godot 工具运行该项目的 `res://tests/content_update_test.gd`，不要在正式项目中运行测试脚本。
2. 回归包括新增商品/地点、未知/下架/alias、旧旅行/相册/信件、已购数值、无效路径/脚本/校验和/链接/版本、保存失败回滚。测试使用内存账本，不写正式 save。实际文件系统原子安装、重启恢复、Android 文件选择器另需 Godot/实机验收。
3. `python tools/android_package.py` 生成 Android Debug preset、精确资源白名单 `dist/android-runtime-allowlist.json`，检查正式 .import 与七张旅行图。不修改原 Web preset。
4. 使用 JDK 17、官方 Godot 4.7.2 Android 模板、Android SDK 36 与 debug keystore。preset 为 `Android Debug`，包名 `com.fishroom.game`，竖屏，INTERNET 权限，无 Gradle 自定义构建，输出 `dist/fishroom-debug.apk`。
5. 由主对话调用 `godot_export_project` 导出 debug APK；没有 godot_* 工具时停在配置完成状态，不通过 shell/Node 启动 Godot。
6. 导出后执行 `python tools/android_package.py --audit dist/fishroom-debug.apk`，核对 APK 和内部 PCK 清单；用 SDK 的 aapt 检查包名/竖屏/权限，用 apksigner 验证签名，再用 adb 安装到已授权设备。无 DSH 首次启动须能进入商店、旅行和日记空状态，9090 不监听，DEV 入口不存在。
7. 开发 MCP 已移出 autoload，仅编辑器调试条件下动态加载；Android 与 fishroom_clean feature 同时防护。DevPanel 不属于 Android 白名单。运行包禁止 logs/docs/tests/个人目录/外部 runtime/角色卡/正式或测试存档/配置/调试代码。
8. 发布 ZIP 外层放 APK、本文、玩家接入文档及必要许可。不要把文档塞进 APK。若需要电脑 runtime，另行准备已参数化且无个人数据的发行版，不把开发 integrations 原目录打包。

导出工具尚不可用时，白名单预审不能代表 APK 实物验收；必须在最终导出后审计 APK。完成后核对正式档 SHA256，与备份一致则无需恢复；若被测试意外改动，停服务后从备份恢复并再次核验。

环境要求与预设选项以 [Godot Android 导出文档](https://docs.godotengine.org/en/4.7/tutorials/export/exporting_for_android.html)、[4.7.2 官方模板](https://godotengine.org/download/archive/4.7.2-stable/)和该版本源码为准。
