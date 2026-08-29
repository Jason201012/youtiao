# 有条（Youtiao）数据格式白皮书

> 版本：v2.7.0（versionCode 91）
> 最后核对：2026-08-28（随 P1-9「每月倒数第 N 天」同步更新）
> 适用范围：备份 JSON、加密信封、iCal UID 映射、附件目录结构

本文目的是把「有条」落在本机磁盘上的数据格式**完整写清**，供三类读者使用：

1. **用户**——确认自己的数据存在哪里、是什么格式、能否自行取用；
2. **审计**——复用统一口径核对「本地优先 / 零联网」主张；
3. **未来的自己**——跨版本迁移时有据可依，避免凭印象改格式。

全文所有字段均以 `lib/` 下的实际序列化代码为准（`Task.toJson`、`TaskProvider.backupData`、
`BackupCrypto.encrypt`、`IcalExporter`、`AttachmentService`），不写推测内容。

---

## 0. 总体原则

| 原则 | 说明 |
|---|---|
| **本地优先** | 全部数据落在应用私有目录，App 自身**不发起任何网络请求**（唯一例外是应用内更新检查） |
| **明文可读** | 默认备份是带缩进的明文 JSON，用户可自行打开、diff、版本管理 |
| **可选加密** | 口令加密是叠加在明文之上的「信封」，解密后仍是同一份 JSON |
| **向后兼容** | 所有新增字段必须有缺省值，旧备份无需迁移即可读入 |
| **宁漏勿错** | 解析外来数据时，任何无法确认的片段宁可丢弃，也不猜 |

---

## 1. 备份 JSON（明文）

### 1.1 顶层结构

由 `TaskProvider.backupData()` 生成，当前 `version = 3`：

```json
{
  "version": 3,
  "app": "有条",
  "tasks": [ /* Task 对象数组 */ ],
  "trash":  [ /* 回收站任务，结构与 tasks 一致 */ ],
  "notifications_enabled": true,
  "sound_enabled": true
}
```

恢复时的结构校验（`restoreFromJson`）：`app != '有条'` **且** `tasks` 不是数组时才拒绝——
即只要二者之一成立就放行，避免误选到其它应用的文件时把用户数据清空。

### 1.2 Task 字段表

| 字段 | 类型 | 缺省 | 说明 |
|---|---|---|---|
| `id` | String | `''` | 任务 id。空串表示「待分配」，入库时由 `TaskProvider` 生成 |
| `title` | String | — | 标题，空标题不允许创建 |
| `priority` | enum | `medium` | `high` / `medium` / `low` |
| `category` | enum | `work` | `work` / `life` / `study` |
| `dueDate` | ISO-8601? | `null` | 截止时间 |
| `startDate` | ISO-8601? | `null` | 开始时间。**P1-5 起用于承载日期区间起点**（如「周五~周日」的周五） |
| `status` | enum | `todo` | `todo` / `done` |
| `done` | bool | — | **旧字段保留**，仅供历史备份兼容，新数据以 `status` 为准 |
| `completedAt` | ISO-8601? | `null` | 完成时刻 |
| `subtasks` | Array | `[]` | 子任务，元素为 `{id, title, done}` |
| `deletedAt` | ISO-8601? | `null` | 非空表示在回收站 |
| `repeat` | enum | `none` | `none` / `daily` / `weekly` / `interval` / `weekday` / `monthly` |
| `repeatWeekdays` | int[] | `[]` | 每周重复的星期（1=周一 … 7=周日） |
| `repeatInterval` | int | `2` | 「每隔 N 天」的 N |
| `repeatMinute` | int? | `null` | 重复提醒时刻（自 00:00 起的分钟数） |
| `repeatAnchor` | ISO-8601? | `null` | 「每隔 N 天」的锚点日（date-only） |
| `skipDates` | String[] | `[]` | 跳过的日期，元素为 `yyyy-MM-dd` |
| `repeatUntil` | String? | `null` | 重复结束日 |
| `monthlyDay` | int | `1` | 每月 N 号；溢出月份自动夹到当月最后一天 |
| `monthlyWeekday` | int? | `null` | 每月第 N 个周几（1..7） |
| `monthlyWeekIndex` | int? | `null` | 第几个（1..4），`5` = 最后一个 |
| `monthlyFromEnd` | int | `0` | **P1-9 新增**：每月倒数第 N 天。`0` = 未启用，`1` = 最后一天，`2`/`3` = 倒数第 2/3 天。优先级高于上述三者 |
| `note` | String | `''` | 备注。**P1-5 起承载快速录入的 `@地点` 与「预计 N 分钟」** |
| `tags` | String[] | `[]` | 自定义标签 |
| `focusSecTotal` | int | `0` | 累计专注秒数 |
| `order` | double | — | 手动排序权重 |
| `reminderOffsetMin` | int | `0` | 提醒提前量（分钟） |
| `pinned` | bool | `false` | 是否置顶 |
| `pinyinInitials` | String | `''` | 拼音首字母，恢复后统一重算（旧备份多为空串） |
| `updatedAt` | ISO-8601? | `null` | 最后更新时间 |
| `attachments` | Array | `[]` | 附件引用，元素为 `{fileName, type, size, addedAt}` |

> **每月重复的三种语义互斥**：`monthlyFromEnd > 0` 时优先；否则若 `monthlyWeekday` 与
> `monthlyWeekIndex` 均非 null 则按「第 N 个周几」；最后才回落到 `monthlyDay`。

### 1.3 自动快照（`backup/auto/`）

App 每日自动写入 `<应用文档目录>/backup/auto/yyyy-MM-dd.json`，在 §1.1 基础上追加：

```json
{
  "version": 3, "app": "有条", "tasks": [], "trash": [],
  "notifications_enabled": true, "sound_enabled": true,
  "focus_sessions": [],                 // 专注记录（FocusProvider.sessionsJson）
  "habits": [], "check_ins": [],        // 习惯与打卡（HabitProvider.backupData）
  "prefs": {},                          // App 级偏好（排除生物特征/更新检查/运行中的计时器）
  "attachments": {}                     // 附件二进制，base64 内联
}
```

- **滚动保留最近 7 份**，更早的自动删除（按文件名 `yyyy-MM-dd` 字典序排序）。
- 附件以 base64 内联，保证单份快照即可完整还原，不依赖外部目录。

---

## 2. 加密信封（口令备份）

口令加密不改动明文本身，而是把整份 JSON 字节加密后包一层信封（`BackupCrypto`）。

### 2.1 结构

```json
{
  "format": "youtiao-backup",
  "v": 3,
  "encrypted": true,
  "kdf":  { "alg": "pbkdf2-hmac-sha256", "iterations": 350000, "salt": "<base64 16B>" },
  "aead": { "alg": "aes-256-gcm",        "iv": "<base64 12B>", "tag": "<base64 16B>" },
  "ct":   "<base64 密文>"
}
```

`ct` 解密后即为 §1 的明文备份 JSON 原样字节。

### 2.2 参数与校验

| 项 | 取值 | 说明 |
|---|---|---|
| KDF | PBKDF2-HMAC-SHA256 | 迭代 **350,000** 次，贴合 OWASP 30–60 万建议 |
| 密钥长度 | 256 bit | — |
| AEAD | AES-256-GCM | 认证标签 128 bit（16 字节），追加在密文尾部 |
| salt | 16 B | 每次加密随机生成 |
| iv | 12 B | 每次加密随机生成 |
| tag | 16 B | GCM 认证标签 |

- 每次加密 salt/iv 均随机，**同一明文多次加密结果不同**（抗重放与字典攻击）。
- **解密前**先做形态校验：`salt` 16B、`iv` 12B、`tag` 16B，任一不符直接拒绝。
- **迭代次数白名单**：解密时限定 `[100000, 5000000]`——下限防弱口令被快速爆破，
  上限防恶意信封用超大迭代次数拖垮 PBKDF2（计算型 DoS）。
- GCM 标签校验失败（口令错 / 文件被篡改）抛 `BackupDecryptException`，UI 提示
  「口令错误或文件损坏」，二者**对外不区分**（避免成为 oracle）。

### 2.3 口令策略

设置口令时强制：**长度 ≥ 8 位，且至少包含两类字符**（`backup_sheet.dart:_isStrongPassword`）。
口令**不落盘**、无找回途径——这是端到端加密的必然代价，UI 已明确告知。

---

## 3. iCal UID 映射

导出（`.ics`）时，每个 `VEVENT` 的 UID 形如：

```
UID:<数字id>@youtiao
```

导入时的反向映射（`IcalParser`）：

1. 取 `UID` 原文，若**以 `@youtiao` 结尾**且前缀可解析为整数 → 采用该数字作为任务 id；
2. 否则（第三方 `.ics` 无 UID 或带其它后缀）→ id 留空，入库时分配新 id。

这样「有条 导出 → 有条 导入」是**幂等**的：`TaskProvider.importDedup` 可按 id 直查现有任务去重。
进一步的防护（v2.7.0 安全修复）：仅当 id 为纯数字、小于当前 id 序列、且指纹（标题+截止日）一致时
才复用；指纹不一致时视为可疑外部 id，**改为新建任务而非覆盖用户既有数据**。

---

## 4. 附件目录结构

全部位于 `<应用文档目录>/attachments/`：

```
attachments/
├── <taskId>/                 正式附件，按任务 id 分目录
│   └── <fileName>
└── _staging/                 暂存区（新建任务尚未入库时使用）
    └── <sessionId>/
        └── <fileName>
```

- `taskId` 与 `fileName` 均需通过白名单校验（`_isSafeSegment` / `_safeFileFor`）后才可落盘或读取，
  防止备份文件中夹带的 `../` 造成路径穿越（CWE-22）。
- 任务被删除时，其附件由 `AttachmentService` 的孤儿回收流程清理；回收前会把**所有**任务引用的
  文件名按 id 合并后再比对，避免 id 碰撞导致误删（v2.7.0 修复）。

---

## 5. 其它本地文件

| 路径 | 用途 |
|---|---|
| `backup/auto/yyyy-MM-dd.json` | 自动快照（§1.3），滚动保留 7 份 |
| `templates/user/<id>.json` | 用户自定义模板 |
| 应用私有 SQLite `youtiao.db` | 任务主存储（SharedPreferences 迁移后） |

用户模板的 `id` 直接用作文件名，因此**强制白名单** `[A-Za-z0-9._-]`、最长 128 字符，
并拒绝 `.` / `..` 与任何含 `/`、`\` 的输入；导入的模板一律重新分配 id。

---

## 6. 兼容性策略

1. **新增字段必须给缺省值**——旧备份读入时走 `?? 缺省`，零迁移。例：`monthlyFromEnd` 缺省 `0`。
2. **不删字段**——即使语义已被取代（如 `done`），仍保留写入，供历史备份读取。
3. **未知枚举值拒绝而非猜测**——恢复流程会「干跑解析」全部任务，任一条非法即在
   覆盖内存态之前抛错，保证失败时用户数据完好。
4. **外来数据一律净化**——iCal UID、模板 id、附件文件名三者都是不可信输入，均有独立白名单。

---

## 附：本轮（v2.7.0 维护批次）新增的语义

| 项 | 落点 | 说明 |
|---|---|---|
| 日期区间（`周五~周日`） | `startDate` + `dueDate` | 复用既有字段，不新增模型字段 |
| 预估时长（`45分钟`） | `note` | 文本形式，未来与专注预设打通时再提升为结构化字段 |
| 地点（`@公司`） | `note` | 文本形式 |
| 每月倒数第 N 天 | `monthlyFromEnd` | 新增模型字段，缺省 `0`，向后兼容 |
| 专注中断次数 | `FocusSession.interruptCount` | 缺省 `0`，向后兼容 |
