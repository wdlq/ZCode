# Windows 7 上的 Electron 41 桌面版（实验记录）

> 状态：**实验已验证可运行**（2026-10-25）。非官方支持路径，升级 Electron 需重新打补丁。

## 1. 结论

ZCode 桌面版固定使用 Electron 41.0.3（内置 Chromium 146.0.7680.80 / Node 24.14.0）。
按 Chromium 官方的支持范围，Windows 7 早已不在支持列表内，常规判断是"打不开"。
实测结论是：**在二进制层面做两处改造后，Electron 41 桌面版可以在 Windows 7 SP1 上完整运行**，
包括窗口、React 渲染、模型对话和 Bash 工具调用。

两处改造缺一不可：

1. **修改 `ZCode.exe`（即 electron.exe）的 PE 可选头 SubsystemVersion**：`10.0` → `6.1`。
2. **为该 exe 的绝对路径注册 VxKex-NEXT 过滤项**，补齐 Win8/Win10 才有的导出函数。

## 2. 为什么原样运行会失败

| 阶段 | 现象 | 原因 |
| --- | --- | --- |
| 原样运行 | `The specified executable is not a valid application for this OS platform`（Win32 错误 `%1 is not a valid Win32 application`） | PE 可选头 `MajorSubsystemVersion = 10`，Win7 加载器在映射镜像前就拒绝，VxKex 没有介入机会 |
| 只打补丁、不注册 VxKex | 进程秒退 `0xC0000139`（STATUS_ENTRYPOINT_NOT_FOUND） | Chromium 146 依赖 Win8+ 的 kernel32 导出 |
| 打补丁 + 注册 VxKex | 正常运行 | VxKex 注入兼容层后补齐缺失导出 |

读取到的原始 PE 信息（`electron.exe`，PE32+ / AMD64）：

```
subsystemVersion: 10.0
osVersion:        10.0
subsystem:        2 (GUI)
```

## 3. 具体做法

### 3.1 PE 补丁

PE32+ 可选头里 `MajorSubsystemVersion` 位于 `e_lfanew + 24 + 48`（2 字节），
`MinorSubsystemVersion` 在 `+50`；`MajorOperatingSystemVersion` / `Minor` 在 `+40` / `+42`。
把 10.0 改成 6.1 即可，等价于 `editbin /SUBSYSTEM:WINDOWS,6.01 ZCode.exe`。

仓库内可直接复用的脚本（本次使用）：读取 `e_lfanew` → 校验 `PE\0\0` → 覆写上述 4 个 WORD。

### 3.2 VxKex 过滤项

和 [Web 模式文档](./windows7-web-mode.md) 里 `node.exe` 的做法一致，只是键名换成真实 exe 名：

```text
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\ZCode.exe
├─ UseFilter = 1
└─ VxKex_ZCODE_DESKTOP
   ├─ FilterFullPath        = <ZCode.exe 绝对路径>
   ├─ KEX_DisableForChild   = 0
   ├─ KEX_DisableAppSpecific= 0
   ├─ KEX_WinVerSpoof       = 0
   ├─ KEX_StrongVersionSpoof= 0
   ├─ GlobalFlag            = 0x100
   ├─ VerifierFlags         = 0x80000000
   └─ VerifierDlls          = kexdll.dll
```

`FilterFullPath` 必须与真实路径完全一致；换目录后要更新，否则补丁无效、进程秒退。

## 4. 打包布局

桌面版按"解包运行"方式组装，不经过 electron-builder（避免其原生资产校验与安装器链路）：

```text
<安装目录>\
├─ ZCode.exe                 electron.exe 改名并打补丁
├─ *.dll / *.pak / locales\  Electron 运行时（原样）
└─ resources\
   ├─ app\                   ZCode 应用
   │  ├─ package.json        main = out/main/index.js, type = module
   │  ├─ out\                main / host / preload / renderer / scheduler / plugin-sandbox
   │  ├─ node_modules\       仅主/宿主运行时的外部依赖（不含 @zcode/* 与 React）
   │  └─ bundled-agents\
   ├─ glm\                   Agent 运行时（zcode.cjs + packages\ 下的官方插件）
   └─ config\                default.json / provider\zcode-builtin.json
```

要点：

- `resources\app` 存在时 Electron 优先于 `default_app.asar`，因此不需要 asar。
- 主/宿主进程的外部依赖名单以 `packages/desktop` 的 `dependencies` 为准（排除 `@zcode/*`
  与 `react`/`react-dom`，前者已被 tsup 内联，后者只服务渲染器）。
- **`resources\config` 不能漏**：缺少时主进程会报
  `ENOENT ... resources\config\default.json`。
- **`resources\glm\packages` 不能漏**：必须由 `pnpm --filter @zcode/desktop run prepare:agent-bundle`
  产出（含 `browser-use-plugin` 等官方插件）。缺它时 Browser Use 的控制面仍可调用
  （`list` 能通），但模型没有 `control-browser` 技能，会退回第三方浏览器技能。

## 5. 实测矩阵（Windows 7 SP1 x64，VMware，6 vCPU / 12 GB）

| 项 | 结果 |
| --- | --- |
| `ZCode.exe --version` | ✅ `v41.0.3` |
| 主进程启动 / `app.whenReady` | ✅ |
| 创建 BrowserWindow（`sandbox: false`） | ✅ 加载页面 + `executeJavaScript` 正确 |
| 创建 BrowserWindow（`sandbox: true`） | ✅ 同上（沙箱渲染进程可用） |
| 真实应用启动 | ✅ main + host + 8 个进程存活 |
| 渲染进程 | ✅ 标题 `ZCode`，`v4 conversation subscribe` 正常，无 JS 异常 |
| UI 截图 | ✅ 侧栏 / 任务列表 / 输入框 / 自定义标题栏完整 |
| 模型对话 | ✅ 自定义供应商 `GLM-5.3-Flash`，回复正常，耗时约 5 秒 |
| Bash 工具 + 权限确认 | ✅ 弹权限框 → 批准 → 执行 `ver` → 返回 `6.1.7601` |

## 6. 已知问题

| 现象 | 影响 | 说明 |
| --- | --- | --- |
| `Unable to find a primary display. Fallback to fake display` | 无（仅日志噪音） | 这台 VM 没有交互式桌面会话；真实登录桌面不会出现 |
| `os_crypt: Failed to encrypt: 0x5`（拒绝访问） | 可能影响 `safeStorage` 相关功能（如 Chrome cookie 导入） | VxKex 下 DPAPI 受限，属可降级项 |
| `读取 task index meta_json 非法 taskId=...` | 无（历史数据告警） | 复用了 Web 模式写下的任务索引行；干净数据目录不会出现 |
| 未验证：托盘、通知、自动更新、多窗口 | 未知 | 这些是 Windows 10 特性密集区，需逐项实测 |
| 内嵌浏览器（IAB） | 控制面可用、guest 未挂载 | 主进程日志显示 `browserId=iab:<uuid>` 的 `list` / `listUserTabs` / `newTab` 均返回 ok；但无交互桌面会话时渲染器没挂上 `<webview>`，模型侧报“webview 尚未就绪”，关闭标签时报 `BrowserGuestManager.closeTabDurably`。需在真实登录桌面复测；对比见 [浏览器自动化后端](./browser-automation-backends.md) |

## 7. 风险与维护成本

- **非官方支持**：Chromium 146 在 Win7 上的行为不受上游保证，可能在某些页面/编解码场景崩溃。
- **升级即失效**：每次升级 Electron 都要重新打 PE 补丁 + 更新 VxKex 的 `FilterFullPath`。
- **安全边界**：VxKex 会改写版本与 API 行为；`--no-sandbox` 只在沙箱确实无法启动时才考虑，
  本次未使用。
- **分发**：这套改造只适合内部/自用，不适合作为公开分发包（需要改签名后的二进制）。

## 8. 复现步骤

```text
1) 取 electron-v41.0.3-win32-x64.zip（或仓库 node_modules/electron/dist），解包到安装目录。
2) 把 electron.exe 改名为 ZCode.exe，修改 PE 子系统版本 10.0 → 6.1。
3) 注册 VxKex 过滤项（见 §3.2），需要管理员权限。
4) 组装 resources\app / resources\glm / resources\config（见 §4）。
5) 从交互式桌面直接运行 ZCode.exe；从 SSH/计划任务启动时需用 WMI 创建进程，
   否则会话结束会回收整棵进程树。
```

## 9. 与 Web 模式的关系

两种形态现在都可用，取舍如下：

| 维度 | 桌面版（本文） | Web 模式（`zcode --web`） |
| --- | --- | --- |
| 前提 | 二进制补丁 + VxKex 按路径注册 + 管理员权限 | 无补丁；Node 24 本身已有 VxKex 注册 |
| 启动 | 双击 `ZCode.exe` | 双击启动器，浏览器以应用窗口打开 |
| Electron 能力（内嵌浏览器 / CUA / 托盘 / 更新） | 理论可用，**待逐项验证** | 不可用 |
| 升级维护 | 每次升级需重打补丁 | 只需替换 `app\zcode` |
| 适用 | 想要原生桌面体验、接受维护成本 | 求稳、可长期维护 |

> 桌面版跑通后，[Web 模式文档](./windows7-web-mode.md) 第 9 节的"Agent 侧浏览器自动化（方案 A）"
> 不再是唯一选择：桌面形态自带 `browserControlPort`，Browser Use 可能直接可用（待验证）。
