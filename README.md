# hsr-screen-agent

用 **截图 + 已验证的合成输入** 读取《崩坏：星穹铁道》角色面板数据的 PowerShell 工具集。
不读游戏内存、不注入 DLL、不改游戏文件——它做的事情和你用鼠标点开角色面板、看一眼数字、记下来，完全一样，只是自动化了。

> HSR (Honkai: Star Rail) character-panel screen reader.
> Elevation-aware synthetic input + screenshot capture, driven step-by-step with
> per-click verification. No memory reading, no DLL injection, no game-file patching.

---

## 为什么需要它：三个真实存在的墙

做一个"读游戏面板"的小工具，真正难的不是截图，也不是点击，而是下面这三样。这个仓库主要就是把它们填平。

### 1. 游戏以管理员身份运行，低权限进程点不动它（UIPI）

星穹铁道的 `StarRail.exe` 清单里声明了 `requireAdministrator`，所以它永远以 High 完整性等级运行。
Windows 的 UIPI 规则会**静默丢弃**来自低完整性进程的合成鼠标/键盘事件——表现就是"点了完全没反应，也不报错"。

```
SELF   pid=812336  integrity=Low   elevated=False
TARGET pid=467508  integrity=High  elevated=True
VERDICT=UIPI_BLOCKED
```

`tools/diag-input.ps1` 就是用来先确诊这一点的：它报告自身与目标进程的完整性等级、是否提权，并给出结论。
**先诊断，再动手**——否则你会以为是坐标算错了，然后花几个小时调坐标。

结论：注入器必须以管理员权限运行（`Start-Process -Verb RunAs`，用户需在 UAC 弹窗点"是"）。

### 2. DPI 缩放让"截图坐标"和"点击坐标"不是一回事

截图、光标位置、窗口矩形必须处在同一套坐标系里。脚本一开头统一调用 `SetProcessDPIAware()`，
之后"窗口内的相对坐标 = 截图像素坐标"，屏幕坐标 = 窗口原点 + 相对坐标，三者严格对齐。

### 3. 横向角色条有惯性，松手后还会滑行约 2.5 秒

这是最阴的一个。拖拽角色列表后立刻按固定坐标连点，会点到**滑行中的半格**上——结果是同一个角色被重复采集 3~4 次，而中间某些角色一次都没点到。

实测每 650ms 采样一次的整条签名差异（越小越接近静止）：

```
SETTLE round=1 diff=99999   ← 刚松手，位置完全变了
SETTLE round=2 diff=656
SETTLE round=3 diff=188
SETTLE round=4 diff=57      ← 才真正停稳
```

所以 `tools/hsr-enum.ps1` 的做法是：**拖拽后反复比对整条角色条的缩略签名，直到两帧差异 < 阈值才继续**，而不是傻等一个固定时长。

---

## 它能做什么

| 任务 | 脚本 | 产出 |
|---|---|---|
| 诊断输入可达性（UIPI / 完整性等级） | `tools/diag-input.ps1` | 控制台报告 |
| 截取整屏或指定窗口 | `tools/capture-screen.ps1` | PNG |
| 通用窗口驱动（枚举/聚焦/点击/截图） | `tools/game-ui.ps1` | PNG + 审计日志 |
| 逐角色采集「详情 / 光锥 / 行迹 / 遗器」四页 | `tools/hsr-collect.ps1` | 每角色 4 张 PNG |
| 采集「属性详情」弹窗、角色条探测、翻页 | `tools/hsr-extra.ps1` | 每角色 1~5 张 PNG |
| 抗惯性的角色名单枚举（含去重与重试） | `tools/hsr-enum.ps1` | 每个角色 1 张 PNG + 运行日志 |
| 深度扫描：属性弹窗 + 六件遗器详情 | `tools/hsr-deepscan.ps1` | 每角色 9 张 PNG（详情/属性×2/遗器×6） |
| 属性面板（触摸滚动）+ 星魂页 | `tools/hsr-statsdeep.ps1` | 每角色 4 张 PNG（详情/属性上/属性下/星魂） |
| 以管理员权限启动上述脚本 | `tools/run-elevated.ps1` | — |

采到的 PNG 交给**人或视觉模型**去读（本工具只负责"把面板稳定地摆到镜头前"）。
上位流程通常是：截图 → 识别（OCR / 视觉模型）→ 决策下一步点哪里 → 再截图，逐轮闭环。

---

## 快速开始

```powershell
# 0) 先确认能不能点得动（不需要管理员）
.\tools\diag-input.ps1 -TitleLike '星穹铁道'

# 1) 看一眼当前有哪些窗口、坐标在哪
.\tools\game-ui.ps1 -Action list

# 2) 截一张游戏窗口
.\tools\capture-screen.ps1 -WindowTitle '星穹铁道' -OutDir .\shots

# 3) 采集一个角色的四页（需要管理员，会弹 UAC）
.\tools\run-elevated.ps1 -File .\tools\hsr-collect.ps1 -Arguments '-Pilot','-OutDir','C:\tmp\shots\pilot'
```

`run-elevated.ps1` 只是把 `Start-Process -Verb RunAs` 包了一层，并把退出码带回来：

```powershell
.\tools\run-elevated.ps1 -File .\tools\hsr-collect.ps1 `
  -Arguments '-MaxChars','9','-OutDir','C:\tmp\shots\sweep'
```

> 提权后的子进程工作目录与你的终端不同，**写入路径请用绝对路径**。

输出目录里除了 PNG，还会写 `_run.log`（每步时间戳、坐标、判定结果）和 `_done.txt`（结束标记），
便于出问题时回溯"到底点在哪一步"。

---

## 安全边界（重要）

这些脚本会**操控你的鼠标和键盘**，所以设计上做了硬性约束：

- **只点白名单坐标**：左侧查看类标签（详情/光锥/行迹/遗器）、顶部角色头像、属性详情按钮。
  脚本里根本不存在指向"强化 / 分解 / 替换 / 购买 / 确认"的坐标。
- **点击前校验前台窗口**：前台不是目标窗口就抛 `LOST_FOREGROUND` 中止，绝不盲点。
  若目标进程与注入进程完整性等级不匹配，`diag-input.ps1` 会提前告诉你。
- **每次点击先对齐再点**：先 `SetForegroundWindow`，抢不到焦点就重试，最后兜底点一下标题栏（不会触发游戏内 UI）。
- **全量审计**：所有动作写入 `_run.log`，坐标、原因、判定结果都可追溯。
- **默认不点最右侧被裁切的头像**：点它会触发角色条自动滚动，是位置漂移的主要来源。

即便如此，**运行期间不要同时操作电脑**。跑之前请自己确认游戏停在角色面板这类只读界面。

---

## 已知限制

- **只读**：工具不会替你强化、分解、替换任何东西，也不做资源规划。
- **需要人类在场的 UAC**：每次提权都要点一次"是"。无人值守场景请改用游戏工具自身的定时任务。
- **分辨率/窗口尺寸相关**：坐标表是按 1942×1136 的游戏窗口实测的；
  换分辨率、换窗口大小、换 UI 缩放都会让坐标失效，需要重新测量（`-Action list` + 截图 + 画点校验）。
- **角色条枚举仍可能有个别缺口**：长列表在末端会被夹紧，点击后名字面板刷新慢于等待时间时会被误判为"未换人"。
  脚本已用签名比对 + 抖动重试缓解，但**不保证 100% 覆盖**；重要场景建议配合人工抽查。
- **动画/加载导致误判**：刚切页时的淡入动画会影响签名比对，必要时加大 `IntervalMs`。
- **属性详情弹窗的滚动方式**：合成滚轮和滚动条拖拽**都无效**，只有**触摸式拖动**
  （在内容区按住并分步向上拖）管用；`hsr-statsdeep.ps1` 已实现（见 `DragPanelUp`）。
  若游戏更新后失效，先怀疑这一点。
- **`hsr-enum.ps1` 是早期版本**：它用的是降采样灰度签名（阈值 400），实测同角色与不同角色的
  差值分布重叠，会漏角色。`hsr-deepscan.ps1` 已换成二值化汉明距离，**新项目请直接用 deepscan**。

---

## 不包含什么

本仓库**不含任何账号数据**：没有游戏截图、没有角色/遗器数据导出、没有 UID、没有日志。
只包含脚本与文档。你用自己的账号跑出来的图，请自己保管。

---

## 免责声明

- 本项目与米哈游 / HoYoverse 无关，不含任何游戏资源文件。
- 游戏自动化可能违反游戏服务条款，存在账号风险。**仅限个人研究与自用，风险自负。**
- 工具只做"读面板"这一件事：不读内存、不注入、不改包、不规避反作弊。但它仍然是自动化输入，请自行评估。
- 严禁用于商业用途、代练、账号交易等场景。

## License

MIT，见 [LICENSE](LICENSE)。
