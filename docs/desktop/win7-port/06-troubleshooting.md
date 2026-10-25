# 06 · 排障手册（症状 → 根因 → 修复）

> 先按"症状"定位，再看"根因"理解为什么，最后照"修复"做。所有条目都来自实机踩坑。

## A. 进程根本起不来

### A1. `0xC0000139` / 进程秒退且无任何输出

**根因**：VxKex 过滤项按**绝对路径**匹配，但当前 exe 没被注册（换目录、重装、拷贝副本都会失效）。

**确认**：

```powershell
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\node.exe" /s
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\ZCode.exe" /s
# 看 FilterFullPath 是否等于当前实际路径
```

**修复**：重新运行安装器（会自动写），或手工补一条 `VxKex_*`（格式见 01）。
Web 启动器也会自愈（`Ensure-NodeVxKexFilter`）。

### A2. `不是有效的 Win32 应用程序` / `not a valid application for this OS platform`

**根因**：`ZCode.exe` 的 PE 子系统版本仍是 10.0，Win7 加载器在映射前就拒绝。

**修复**：打 PE 补丁（+40/+42、+48/+50 → 6.1），见 03。

### A3. 双击 `启动 ZCode.cmd` 报 `Write-Host : Win32 internal error "A device attached ..." 0x1F`

**根因**：`.cmd` 里 `chcp 65001` 或脚本里 `[Console]::OutputEncoding = UTF8` 把控制台切成 UTF-8，
Win7 点阵字体渲染中文失败；加上 `$ErrorActionPreference = "Stop"`，写日志失败直接中断启动。

**修复**（已在启动器中实现）：

- `.cmd` **不要** `chcp 65001`
- 只有 `[Console]::IsOutputRedirected`（SSH/管道）时才设 UTF-8
- 所有输出走 `Write-Status`，失败降级为 ASCII，不中断

若仍看到**乱码**（不是报错）：控制台属性 → 字体改成「新宋体」或「Lucida Console」。

### A4. 启动器报"启动成功"但端口瞬间消失

**根因**：`Start-Process` 拉起的子进程留在调用方 Job 里；从 SSH/计划任务启动时，父会话结束会
连带杀掉 server。

**修复**：用 `Win32_Process.Create` 创建进程（启动器已实现），或直接在桌面会话里双击。

## B. 构建与打包

### B1. `pnpm build:zcode` 报 `spawnSync pnpm ENOENT`

**根因**：`scripts/build-zcode.mjs` 早期用 `spawnSync("pnpm")`；Windows 上 `pnpm` 是 `.cmd` shim，
`spawnSync` 只找 `.exe`。

**修复**：已改为复用 `scripts/spawn-command.mjs` 的 `runCommand`（内部 `shell: true`）。

### B2. 组装时报 `Missing @zcode/shared dist files`

**根因**：`@zcode/shared` 没有 build 脚本，`dist/index.js` 由 `tsc -b` 产出。

**修复**：先 `node node_modules/typescript/bin/tsc -b packages/shared`。

### B3. 打包后 server 启动报 `Cannot find package '@zcode/services'`

**根因**：最后一次跑的是 `pnpm typecheck`，它把 `packages/server/dist/entry-http.js` 覆盖成
未打包的 tsc 产物（几 KB）。

**修复**：组装前重新 `pnpm --filter @zcode/server build`，确认 `entry-http.js` 约 5 MB。

### B4. 桌面版启动报 `ENOENT ... resources\config\default.json`

**根因**：组装时漏拷仓库根 `config\` 到 `resources\config\`。

**修复**：补上 `config\default.json` 与 `config\provider\`。

### B5. `-sfx7zCon.sfx` 报 `cannot find specified SFX module`

**根因**：7-Zip 找不到 SFX 模块（与 cwd/模块名有关）。

**修复**：`cd` 到构建目录后用 `-sfx`（默认模块），或把 `7zCon.sfx` 复制到 cwd 再指定。

### B6. 安装器体积异常大 / 构建很慢

**根因**：对已经压缩好的 `payload.zip` 再压缩。

**修复**：SFX 用 `-mx0`（store）。

## C. 运行时

### C1. 模型说"当前环境没有可用的浏览器后端"，随后去调用 Tabbit

**根因**（两种，先分清形态）：

| 形态 | 根因 |
| --- | --- |
| Web 版（标题 `ZCode - Web + Server`） | 设计如此，没有 `browserControlPort` |
| 桌面版 | `resources\glm\packages\browser-use-plugin` 缺失 → 没有 `control-browser` 技能 |

**修复**：

- Web 版：用 `tools/browser-verify.mjs`（见 04），不要再试 `agent.browsers`
- 桌面版：重新执行 `pnpm --filter @zcode/desktop run prepare:agent-bundle` 并重新组装 `resources\glm`

### C2. 桌面版内置浏览器报"webview 尚未就绪"

**根因**：Agent 已 `newTab`，但渲染器没挂上 `<webview>`。无交互桌面会话（SSH/计划任务）时高发。

**修复**：在本地桌面会话里双击启动；确认 `[browser-use] execute ... method=newTab ok=true`
之后还有 `goto`/`snapshot`。仍失败时先用 `browser-verify.mjs` 兜底。

### C3. Web 版建项目报 `project.host-offline` / 保存报 `project.host-immutable`

**根因**：浏览器只传 `hostId: "local"`，独立 Server 的持库 identity 是 `remote:server:<id>`。

**修复**：已在 `packages/services/src/project/index.ts` 归一（见 07）。升级时不要回退这段。

### C4. Web 版首页直接发消息报 `project.remote-project-required`

**根因**：Web 形态没有 Window Host Controller，必须先有项目。

**修复**：选择项目 → 创建项目 → 在项目下新建任务。

### C5. 装完桌面版发现任务列表是空的

**根因**：桌面版用 `%APPDATA%\ZCode`，Web 版用 `%USERPROFILE%\.zcode`。

**修复**：不是故障；需要迁移时自行复制数据目录（注意 SQLite 版本兼容）。

### C6. 日志出现 `os_crypt: Failed to encrypt: 拒绝访问 (0x5)`

**根因**：VxKex 下 DPAPI 受限。

**影响**：Chrome cookie 导入等非核心功能；不影响会话与模型调用。

### C7. 日志出现 `读取 task index meta_json 非法 taskId=...`

**根因**：任务索引里混入了旧数据（例如 Web 版与桌面版共用过同一份索引）。

**影响**：仅告警，不影响新会话。彻底解决用干净的数据目录。

### C8. 启动器提示"端口已被占用但不是当前 token 的实例"

**根因**：上一次只杀了父进程，子进程仍持有端口。

**修复**：启动器会自动清理本安装目录下的 node 进程再启动；也可以用「停止 ZCode Web 版」。

## D. 快速自检清单（排障前先跑一遍）

```powershell
# 1. 系统与 PS
[Environment]::OSVersion.VersionString
$PSVersionTable.PSVersion

# 2. VxKex 是否装了
Test-Path "C:\Program Files\VxKex\Kex64\KxBase.dll"

# 3. 两个 exe 的过滤项是否指向当前路径
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\ZCode.exe" /s
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\node.exe" /s

# 4. 桌面端（用调试启动器后）
Invoke-WebRequest http://127.0.0.1:9333/json/version -UseBasicParsing

# 5. Web 端
Invoke-WebRequest http://127.0.0.1:3030/api/server-info -UseBasicParsing
```
