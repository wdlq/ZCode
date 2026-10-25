# 02 · Web 形态（`zcode --web`）

## 1. 为什么需要它

ZCode 桌面版依赖 Electron 41（Chromium 146），而 Chromium 自 109 起不再支持 Windows 7。
Web 形态只要求 **Node 24 + 一个 Chromium 109+ 浏览器**，因此在 Win7 上是最稳的路径。

```text
浏览器（Supermium / BrowserOS）
   │  http://127.0.0.1:3030  +  /ws
   ▼
Node 24（web\runtime\node.exe）
   └─ packages/server entry-http.js
        ├─ Web UI 静态资源（packages/web dist）
        ├─ createServerHostServices()：会话/任务/文件/Git/终端…
        └─ fork：zcode.cjs app-server --stdio（每个 workspace 一个 Agent）
```

## 2. 部署布局

```text
<安装目录>\web\
├─ app\zcode\               发行包（web / server / agent / node_modules）
├─ runtime\node.exe         Node 24（必须已注册 VxKex）
├─ launcher\start-zcode.ps1 启动器
├─ launcher\stop-zcode.ps1  停止器
├─ logs\                    运行期生成
└─ 启动 ZCode Web 版.cmd     （安装器在顶层也放了一份）
```

## 3. 启动器设计（每个细节都有原因）

| 设计 | 原因 |
| --- | --- |
| 用 `Win32_Process.Create` + `cmd.exe` 重定向日志启动 | `Start-Process` 的子进程留在调用方 Job 里；从 SSH/计划任务启动时，父会话结束会连带杀掉 server（现象：脚本报成功但端口瞬间消失） |
| 端口已占用且 probe 不通时先清理残留进程 | 父进程被 kill、子进程仍持端口会让新实例 `EADDRINUSE`，随后探测一直 401/超时 |
| 就绪探测带 token | 非回环监听会强制 token，不带 token 的 `/api/server-info` 返回 401，会把"已就绪"误判成失败 |
| `-LanAccess` 自动生成并持久化 token | 非回环必须鉴权；token 写 `logs\lan-token.txt`，重启复用 |
| 全部输出走 `Write-Status` | 控制台写入失败只降级不中断（见 06 的 0x1F 条目） |
| 启动前自动补 VxKex 注册 | 换目录后 `node.exe` 会 `0xC0000139` 秒退；脚本检测并补写 |
| 不用 `chcp 65001` | Win7 点阵字体下 PowerShell 写中文会抛 0x1F（详见 06） |

常用参数：

```powershell
start-zcode.ps1                        # 默认 127.0.0.1:3030，打开浏览器
start-zcode.ps1 -Port 3031             # 换端口
start-zcode.ps1 -Workspace D:\code     # 换工作区
start-zcode.ps1 -Foreground            # 前台运行（看实时日志）
start-zcode.ps1 -NoBrowser             # 只起服务
start-zcode.ps1 -LanAccess             # 0.0.0.0 + token（局域网访问）
```

## 4. 能力边界（与桌面版的差异）

| 能力 | Web 版 |
| --- | --- |
| 会话 / 任务 / 工具 / 队列 / 快照 | ✅ 与桌面版同一套服务 |
| 终端（node-pty） | ✅ Win7 上实测可 spawn |
| 内嵌浏览器 IAB / Browser Use | ❌ **没有**（宿主不注入 `browserControlPort`） |
| 托盘、通知、自动更新、多窗口、CUA | ❌ |
| 左侧"全局任务列表"（Window Host Controller） | ❌（见 `docs/zcode-lite-static-distribution.md`） |
| 浏览器自动化替代方案 | `tools/browser-verify.mjs`（Playwright + Supermium）或 Tabbit，见 04 |

## 5. 首次使用必须先建项目

Web 形态没有桌面窗口的 Window Host Controller，服务端项目的持库 identity 是
`remote:server:<id>`，而浏览器只传 `hostId: "local"`。原实现会把 `local` 当成外部 host，
导致 `project.host-offline` / `project.host-immutable`。

已在 `packages/services/src/project/index.ts` 修复（见 07）。使用上的结果是：

1. 首次必须「选择项目 → 创建项目」并信任文件夹；
2. 在项目下「新建任务」后才能发消息；
3. 直接在工作区首页发消息会报 `project.remote-project-required`。

## 6. 局域网访问

```powershell
web\launcher\start-zcode.ps1 -LanAccess -Port 3030
```

- 监听 `0.0.0.0`，token 写 `<安装目录>\web\logs\lan-token.txt`
- 访问 `http://<本机IP>:3030/?token=<token>`
- 首次需要放行防火墙：
  `netsh advfirewall firewall add rule name="ZCode Web 3030" dir=in action=allow protocol=TCP localport=3030`

## 7. 数据与日志

| 位置 | 内容 |
| --- | --- |
| `%USERPROFILE%\.zcode` | 设置、provider、会话、SQLite |
| `<安装目录>\web\logs\server.out.log` | 主日志（含每条 RPC 调用） |
| `<安装目录>\web\logs\server.err.log` | 启动错误、Electron/SQLite 警告 |
| `<安装目录>\web\logs\lan-token.txt` | 局域网 token |

排查顺序：先看 `server.err.log` 是否有 `ERR_MODULE_NOT_FOUND` / `EADDRINUSE`，
再看 `server.out.log` 里 `[rpc:call] xxx FAIL` 的具体错误码。
