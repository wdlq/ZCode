# Windows 7 Web 模式移植说明

## 1. 结论与范围

ZCode 桌面版固定使用 Electron 41.0.3（内置 Chromium 146.0.7680.80 / Node 24.14.0），
而 Chromium 自 109 起不再支持 Windows 7；VxKex-NEXT 能补齐部分 Win10 API，
但无法让 Chromium 146 在 Win7 上直接启动（PE 子系统版本被加载器拒绝）。
因此在 Windows 7 上最稳妥的交付方式是 **Node 发行包的 Web 模式**：

```text
zcode --web
├─ 本地 HTTP/WS server（packages/server entry-http，Node 24）
├─ Web UI 静态资源（packages/web dist）
└─ Agent 运行时（agent/zcode.cjs app-server --stdio）

浏览器（Supermium / Chromium 109+）→ http://127.0.0.1:3030/ → 同源 /ws
```

本文记录 Win7 移植的边界、部署布局、已验证项和已知差异。运行时能力本身（会话、任务、
工具、队列、快照）沿用既有 Web 模式合同，本移植不新增协议。

> 补充：桌面版也有可行路径（PE 子系统版本补丁 + VxKex 按路径注册），已验证可完成
> 模型对话与 Bash 工具调用，代价是每次升级要重打补丁。详见
> [Windows 7 上的 Electron 41 桌面版](./windows7-electron-shell.md)。

## 2. 目标机要求

| 项 | 要求 | 说明 |
| --- | --- | --- |
| 系统 | Windows 7 SP1 x64 | 已在 6.1.7601 + PowerShell 5.1.14409 验证 |
| 运行库 | .NET Framework 4.5+、VC++ 2015-2022 x64 | VxKex 与 Node 原生模块依赖 |
| 兼容层 | VxKex-NEXT（1.2.x） | Node 22+ 依赖 Win8/Win10 kernel32 导出 |
| Node | 24.x（随包携带 `runtime/node.exe`） | `node:sqlite` 要求 ≥22.5 |
| 浏览器 | Supermium / BrowserOS / Chromium 109+ | Win7 可用的 Chromium 分支 |

### 2.1 VxKex 过滤项按绝对路径匹配

VxKex-NEXT 对每个受控程序在

```text
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\<exe>
├─ UseFilter = 1
└─ VxKex_<name>
   ├─ FilterFullPath       = <exe 绝对路径>
   ├─ KEX_DisableForChild  = 0
   ├─ KEX_DisableAppSpecific = 0
   ├─ KEX_WinVerSpoof      = 0
   ├─ KEX_StrongVersionSpoof = 0
   ├─ GlobalFlag           = 0x100
   ├─ VerifierFlags        = 0x80000000
   └─ VerifierDlls         = kexdll.dll
```

记录一条过滤项，`FilterFullPath` 是**完整路径**。把 `node.exe` 复制到新目录后若只复制文件、
不补这条注册，进程会以 `0xC0000139`（`STATUS_ENTRYPOINT_NOT_FOUND`）秒退，且没有任何
错误输出——现象容易被误判成“脚本有问题”。启动器的 `Ensure-NodeVxKexFilter` 会自动补注册，
需要管理员权限；非管理员运行时会打印提示。

## 3. 部署布局

```text
C:\ZCode\
├─ app\zcode\             ZCode 运行包（web、server、agent、node_modules）
├─ runtime\node.exe       Node 24（随包，自包含；需 VxKex 注册）
├─ launcher\
│  ├─ start-zcode.ps1     启动器（UTF-8 with BOM，PS 5.1 要求）
│  └─ stop-zcode.ps1      只结束本安装目录下的 node 进程
├─ logs\                   server.out.log / server.err.log / lan-token.txt
├─ 启动 ZCode.cmd
├─ 停止 ZCode.cmd
├─ zcode.cmd              CLI/TUI 入口
└─ README.txt
```

启动器要点：

- **UTF-8 with BOM**：PowerShell 5.1 按 ANSI 代码页读取 `.ps1`，无 BOM 的中文注释会导致解析失败。
- **WMI 创建进程**：`Start-Process` 拉起的子进程留在调用方 Job 里，从 SSH/计划任务等会回收
  进程树的上下文启动时，父会话结束会连带杀掉 server（现象：脚本报就绪失败但端口短暂可用）。
  改用 `Win32_Process.Create` + `cmd.exe` 重定向日志，让 server 完全脱离启动器进程树。
- **残留实例自愈**：父进程被杀而子进程仍持有端口时，新实例会 `EADDRINUSE`。启动器在端口被
  占用且探测不通时先清理本安装目录的 node 进程再启动。
- **局域网访问**：`-LanAccess` 绑定 `0.0.0.0` 并强制 token（写 `logs\lan-token.txt`）；
  回环地址仍然免鉴权。
- **不要 `chcp 65001`**：Win7 控制台（点阵字体）在 UTF-8 代码页下，PowerShell 用
  `Write-Host` 写中文会报
  `Win32 internal error "A device attached to the system is not functioning" 0x1F ...
  writing to the console output buffer`；配上 `$ErrorActionPreference = "Stop"` 会直接中断启动。
  现在只在 `[Console]::IsOutputRedirected`（SSH/管道）时切 UTF-8，真实控制台保持本机代码页；
  所有状态输出走 `Write-Status`，即使控制台写入失败也只降级不中断。

## 4. 已验证项（Windows 7 SP1 x64）

- Node 24.21 运行探针 30/30：`node:sqlite`（3.53.4、WAL）、crypto（ed25519/aes-gcm/scrypt）、
  Intl、worker_threads、http、fetch、child_process、WebSocket client。
- Web UI：登录页、引导流程、主界面、任务列表、输入框、设置页、项目选择器全部可交互。
- RPC：全量通道注册（file/git/terminal/zcode-task/zcode-agent/plugin…），`/api/server-info` 正常。
- Agent：`app-server --stdio` 启动并执行 24 个 SQLite 迁移。
- 终端：`node-pty` 在 Win7 上可 `spawn`（不依赖 ConPTY 的构建）。
- 端到端：自定义 Anthropic 兼容供应商 + 云端模型完成一次真实对话，Agent 成功执行 Bash 工具
  并把 Win7 版本与 Node 版本回传（截图见交付说明）。

## 5. 为 Web 形态补的两个修复

### 5.1 `pnpm build:zcode` 在 Windows 上无法启动子进程

`scripts/build-zcode.mjs` 原先自带 `spawnSync("pnpm", …)`；Windows 上 `pnpm` 是 `pnpm.cmd`
shim，`spawnSync` 只查 `.exe` 并抛 `ENOENT`。改为复用 `scripts/spawn-command.mjs` 的
`runCommand`（已带 `shell: true` 与含空格参数的引号规则）。

### 5.2 浏览器“此电脑”与独立 Server 持库 identity 不匹配

独立 Server 用 `remote:server:<id>` 作为项目持库 owner，而浏览器端只有一个「此电脑」设备、
固定传 `hostId: "local"`。原实现把它当成外部 host 去解析，导致：

- `project.readDirectory` / 建项目报 `project.host-offline`；
- 保存项目报 `project.host-immutable`；
- 无项目时创建会话报 `project.remote-project-required`。

修复边界：`packages/services/src/project/index.ts`

- `route()`：**没有注入 `resolveHost`** 时（说明本进程自己持这套数据：桌面 local owner 或
  standalone server），把 `"local"` 视为本进程 owner 做本地路由；
- `saveProject()`：路由到本地后把 `"local"` 归一为 `options.ownerHostId` 再写仓库。

远端约束不变：单 root、root 不可变、跨 host 拒绝仍由 `ownerHostId` 判定，不因请求里的
`hostId` 放宽。桌面端行为不变（桌面 ownerHostId 为 `local`，且注入了 `resolveHost`）。

## 6. 已知差异（Web 形态边界，非 Win7 特有）

- 没有 Electron 外壳能力：内嵌浏览器、Computer Use、系统托盘、自动更新、窗口级任务聚合。
- 左侧全局任务列表依赖 Window Host Controller，普通 Web 暂不支持（见
  [ZCode Lite 静态分发](./../zcode-lite-static-distribution.md)）。
- Web 端没有原生目录选择框，走内建目录浏览器；首次必须先创建项目，再在项目下新建任务。
- 未随包提供 ripgrep/ugrep 二进制，Grep 工具回落到纯 JS 搜索（结果一致、速度较慢）。
- `marketing-touch.query` 在 Web 入口缺少参数时报 ZodError、新建任务时 `task-groups.admit`
  可能报 `created-task-unavailable`；两者都是非阻塞提示，不影响会话。

## 7. 构建与部署

```powershell
# 1) 仓库依赖与共享类型产物（@zcode/shared 无 build 脚本，dist 由 tsc -b 产出）
pnpm install
node node_modules/typescript/bin/tsc -b packages/shared

# 2) 构建 CLI / server / web 并组装发行包
pnpm build:zcode --base-url http://example.invalid/zcode/

# 3) 按目标平台裁剪（可选，win32-x64 只需保留 win32-x64 预编译产物与前端资源）
#    - web/**/*.map
#    - node_modules/node-pty/prebuilds/{darwin-*,linux-*,win32-arm64}
#    - agent/node_modules/@mbears/opentui-core-{非 win32-x64}
#    - agent/node_modules/koffi/build/koffi/{非 win32_x64}
#    - agent/node_modules/unsafe-pointer/prebuilds/{非 win32-x64}

# 4) 投递：tar.gz 经共享目录复制到虚拟机，用 7-Zip 解压到 C:\ZCode\app\zcode
"C:\Program Files\7-Zip\7z.exe" x zcode-win7.tar.gz -o<tmp> -y
"C:\Program Files\7-Zip\7z.exe" x <tmp>\zcode-win7.tar -oC:\ZCode\app -y
```

裁剪后体积参考：373.5 MB → 229.9 MB；tarball 83.2 MB → 51.2 MB。

## 8. 验证记录

- 2026-10-24 / Windows 7 Professional SP1 x64（VMware，6 vCPU / 12 GB）
- Node v24.21.0（VxKex-NEXT 1.2.3.2463 已注册 `C:\ZCode\runtime\node.exe`）
- Supermium 150（Chromium 150）经局域网 `http://<vm-ip>:3030/?token=…` 访问
- 自定义供应商：Anthropic Messages 格式，模型 `GLM-5.3-Flash`
- 结果：一次对话内执行 `ver` 与 `node -v`，回复“Windows 7 SP1（6.1.7601）/ Node v24.21.0”

## 9. 待实施：Agent 侧浏览器自动化（方案 A）

> 状态：**仅记录方案，尚未实施**。用户确认后再落地。

### 9.1 为什么需要单独方案

Web 形态拿不到 Electron 宿主注入的 `browserControlPort`，而
`--browser-use=headless` 在 `app-server` 入口被 fail closed，所以模型侧没有原生
Browser Use（`agent.browsers` 不出现）。但 Agent 进程自身仍是 Win7 上的普通 Node 进程，
可以自己拉起一个 Chromium 并通过 CDP 操作——这与“UI 在浏览器里”不冲突。

已实测：用发行包自带的 `agent/node_modules/playwright-core`（1.59.1）以
`executablePath = C:\Program Files\Supermium\chrome.exe` 拉起 Chromium 150，
完成导航、点击「设置 → 模型设置」并截图。

### 9.2 实施范围（不改产品代码）

1. **工作区说明文件**：在默认工作区（`%USERPROFILE%\ZCodeWorkspace`）放一份 `AGENTS.md`，
   写明：
   - 可用浏览器：`C:\Program Files\Supermium\chrome.exe`（Chromium 150，Win7 可用）；
   - 两种驱动方式：`playwright-core` 直接 `launch({ executablePath })`（推荐，headless），
     或先带 `--remote-debugging-port` 启动再用 `connectOverCDP` 复用；
   - `playwright-core` 的实际路径（`C:\ZCode\app\zcode\agent\node_modules\playwright-core`），
     避免模型去联网安装浏览器；
   - 截图/录屏输出到 `artifacts/`，失败时同时 dump console 与页面文本；
   - 禁止把 `--no-sandbox` 当默认，禁止导航到 `file://`/`data:`。
2. **可复用脚本模板**：`tools/browser-test.mjs`（launch → goto → waitReady → 点击/填表 →
   断言文本 → 截图 → 退出码 0/1），让模型只改用例而不用每次重写驱动代码。
3. **dev server 协作约定**：固定端口 + 就绪探测（`/api/health` 或 200 轮询 + 超时），
   失败时保留 dev server 日志。
4. **验收用例（写好后再执行）**：在 Win7 上「起 `vite` dev server → 打开页面 → 点击主按钮
   → 断言文案 → 截图」，并把证据落到 `artifacts/`。

### 9.3 已知风险

- Supermium 150 与 `playwright-core` 1.59.1 的版本跨度较大，个别新 CDP 能力可能不可用；
  必要时改用 `connectOverCDP` 或固定一份兼容的 Chromium。
- headless + 无 GPU 环境下字体/动画与真实窗口有差异，视觉断言需留容差。
- 不要让模型联网下载 Playwright 浏览器；Win7 上只能复用系统已有的 Supermium/BrowserOS。

### 9.4 与另两条路的关系

- 方案 B：`zcode --browser-use=headless --browser-executable=<Supermium>` 走 CLI 原生
  Browser Use（`--prompt` 默认 yolo 权限），但属于独立 CLI 会话，不是 Web 会话。
- 方案 C：由独立 Server 注入 managed CDP `BrowserControlPort`，让 Web 会话也能用原生
  Browser Use；需先改 `docs/browser-use/2026-07-13-cli-headless-cdp-backend-spec.md`
  中“app-server 不得另起 browser runtime”的边界定义。
- 桌面形态：在 Win7 上跑通 Electron 桌面版后自带 `browserControlPort`，原生 Browser Use
  可能直接可用（待验证）。若验证通过，Web 形态就不再需要方案 A。
  见 [Windows 7 上的 Electron 41 桌面版](./windows7-electron-shell.md)。
