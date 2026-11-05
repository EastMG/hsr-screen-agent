# 踩坑记录

这个仓库的价值一半在脚本，一半在这些坑。每一条都是"现象 → 原因 → 修法"，按踩到的顺序排列。

---

## 1. 点击完全没反应，而且不报错（UIPI）

**现象**：脚本执行了 `SetCursorPos` + `mouse_event`，坐标肉眼核对无误，但游戏界面纹丝不动。

**诊断**：先测两个进程的完整性等级。

```
SELF   pid=812336  integrity=Low   elevated=False   ← 我的注入进程
TARGET pid=467508  integrity=High  elevated=True    ← 游戏
VERDICT=UIPI_BLOCKED target is higher integrity; synthetic input will be dropped
CURSOR  移到 -957,967 → moved=False                  ← 连光标都动不了
```

**原因**：星铁 `StarRail.exe` 的清单声明了 `requireAdministrator`，永远以 High 完整性运行。
Windows UIPI（用户界面特权隔离）会**丢弃**低完整性进程发往高完整性窗口的合成输入，且不返回错误。

**修法**：
- 注入器必须以管理员运行：`Start-Process -Verb RunAs`（需要用户点 UAC）。
- 在动手之前先用 `tools/diag-input.ps1` 确认 `VERDICT=INPUT_ALLOWED`，不要瞎调坐标。
- 注意：**降权游戏是行不通的**——清单写死了 `requireAdministrator`，普通启动会被系统自动提权。

检测方法（简化）：`OpenProcess(0x1000)` → `OpenProcessToken(TOKEN_QUERY)` →
`GetTokenInformation(TokenIntegrityLevel)` 取 SID 的 RID（0x1000=Low / 0x2000=Medium / 0x3000=High）。

---

## 2. 中文写进 .ps1 就乱码，进而"找不到窗口"

**现象**：用中文窗口标题做匹配的脚本，报 `ABORT: game window not found`，但窗口明明开着。

**原因**：脚本存成 **UTF-8 无 BOM**，而 Windows PowerShell 5.1 读无 BOM 的 `.ps1` 时按 ANSI/GBK(CP936) 解码，
脚本里的 `'星穹铁道'` 变成乱码，`-like` 自然匹配不上。

**修法**（二选一）：
```powershell
# A. 把脚本转成 UTF-8 with BOM（文件头 EF BB BF）
$p = '.\script.ps1'
$t = [IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($p, $t, [Text.UTF8Encoding]::new($true))
```
```powershell
# B. 干脆别在脚本里写中文——按进程名匹配（本仓库采用）
Get-Process | Where-Object { $_.ProcessName -like '*StarRail*' }
```
B 更稳：`Start-Process -ArgumentList` 传中文参数同样会被 ANSI 化，跨进程传中文标题并不可靠。

> 另注：文本编辑器/工具"重写文件"时经常会顺手去掉 BOM。改完脚本要复查前三字节是不是 `EF BB BF`。

---

## 3. PowerShell 5.1：`0xFFFFFFFF` 不是 4294967295，而是 -1

**现象**：滚轮注入报错
`无法将值"-72000"转换为类型"System.UInt32"`。

**原因**：PS 5.1 里十六进制字面量默认按 int32 解析，`0xFFFFFFFF` 等于 **-1**。
于是想用 `-band 0xFFFFFFFF` 做无符号转换时，结果仍是负数，转 `[uint32]` 直接抛异常。

**修法**：别用掩码，直接加法转换负数：

```powershell
$delta = 120 * $notches                     # 向下滚是负数
if ($delta -lt 0) { $dw = [uint32](4294967296 + [int64]$delta) }
else              { $dw = [uint32]$delta }
[UiX]::mouse_event(0x0800, 0, 0, $dw, [IntPtr]::Zero)   # MOUSEEVENTF_WHEEL
```

同样的坑还会出现在任何把 `int` 传给 `uint` 参数的 P/Invoke 上（`mouse_event` 的 `dwData` 就是 `uint`）。

---

## 4. 别把函数命名为 `Diff`

**现象**：`$d = Diff $a $b` 之后报
`无法将"@{InputObject=52; SideIndicator==>}"与"2147483647"进行比较`。

**原因**：`diff` 是 `Compare-Object` 的内置别名，PowerShell 命令解析**优先匹配别名**，你的函数根本不会被调用。

**修法**：换个名字（本仓库用 `Sig-Delta`），或者显式调用 `& (Get-Command Diff)`。

---

## 5. UAC 关闭后会偷走焦点，脚本第一步就中止

**现象**：`ERROR LOST_FOREGROUND`，日志里连第一个 CLICK 都没记录。

**原因**：提权那一下 UAC 安全桌面/控制台窗口会抢到前台，`SetForegroundWindow` 在短时间内可能被前台锁定策略拒绝。

**修法**：抢焦点要**重试 + 兜底**：

```powershell
for ($i = 0; $i -lt 6; $i++) {
  Focus-Game; Start-Sleep -Milliseconds 350
  if ([UiE]::GetForegroundWindow() -eq $gameHwnd) { return $true }
}
# 兜底：点一下标题栏（只聚焦，不触发游戏内 UI）
```

同时要配合 `AttachThreadInput` 才能可靠地把前台抢过来。

---

## 6. 横向滚动有惯性：松手后还在滑 2.4 秒

**现象**：拖拽角色列表后按固定坐标连点，连续 3~4 次采到同一个角色，同时中间若干角色被跳过。

**量化**：每 650ms 采样一次整条角色条的 32×6 缩略签名，与上一帧求差的绝对值之和：

```
SETTLE round=1 diff=99999   ← 刚松手
SETTLE round=2 diff=656
SETTLE round=3 diff=188
SETTLE round=4 diff=57      ← 稳定
```

也就是说 `mouseup` 之后大约 **2.4 秒**列表才真正静止。之前只等 600ms 就开点，正好点在滑行中的半格上。

**修法**：不要等固定时长，而是**轮询到两帧差异小于阈值**再继续（本仓库阈值 120，最多 6 轮）。
另外：拖拽幅度要小于「每页采样点数 × 头像间距」，保证页与页之间必有重叠，否则会留缺口。

---

## 7. 点完立刻截图，还是上一个人的名字

**现象**：点击头像后 620ms 截图，读出来的是上一个角色；把它当成"重复"重试，反而把当前角色跳过去了。

**原因**：详情页的名字面板刷新慢于固定等待时间（尤其刚切过页面、模型还在加载时）。

**修法**：
1. 点击后等待加长（本仓库 900~1000ms 起）。
2. **不要只看固定延时**：截取名字面板区域（固定矩形），缩成 24×4 的灰度签名，和上一个角色的签名比。
   差异不够大 → 判定"没换人" → **先再等一会儿复查**，仍然没变才抖动坐标重试。
3. 抖动偏移取 ±45 / ±90 px（约等于半格/一格头像间距），失败 4 次就记 `GIVEUP` 并继续，不要卡死。

---

## 8. 最右侧被裁切的头像会让整条列表自动滚动

**现象**：点了部分露出的第 10 个头像之后，后面所有点击的映射全部错位。

**原因**：被裁切的头像被点击时会自动滚入视野，列表位置整体左移半格。

**修法**：只点**完整可见**的槽位；需要覆盖更多角色时，用"小步拖拽 + 每页多点几个槽位"来保证重叠，
而不是去点边缘那个半截头像。

---

## 9. 只读白名单：让"点错"的后果可控

自动化点击最怕的不是点不中，而是**点中不该点的东西**。这个仓库的做法是把风险写死：

- 坐标表里只出现查看类控件（详情/光锥/行迹/遗器/属性详情/角色头像）。
- 代码里**不存在**指向强化、分解、替换、购买、确认的坐标——想点也没有得点。
- 每次点击前校验前台窗口；不匹配就中止（`throw 'LOST_FOREGROUND'`）。
- 打开的弹窗一律用 `ESC` 关闭，而不是去点关闭按钮（按钮位置会随内容浮动）。

---

## 10. 坐标是怎么定出来的（换个分辨率就得重测）

1. `game-ui.ps1 -Action list` 拿到窗口矩形（屏幕坐标 + 宽高）。
2. `-Action capture -TitleLike ...` 截该窗口 → 图片像素坐标与窗口内相对坐标 1:1。
3. 在截图上量出目标控件中心 → `屏幕坐标 = 窗口左上角 + 相对坐标`。
4. **验证**：用 PowerShell 在截图上画出候选点（十字 + 编号）再截图回看，确认落点，再批量跑。

本仓库的坐标表按 **1942×1136** 的游戏窗口实测。换分辨率、换窗口大小、改 UI 缩放都会失效。
