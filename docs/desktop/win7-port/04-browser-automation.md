# 04 · 浏览器自动化：IAB / Playwright / Tabbit

## 1. 先看结论

| 运行形态 | 有 IAB 吗 | 推荐做法 |
| --- | --- | --- |
| **桌面版**（Electron） | 有（`agent.browsers` / `control-browser`） | 优先 IAB |
| **Web 版**（`zcode --web`） | **没有**（宿主不注入 `browserControlPort`） | 用 `tools/browser-verify.mjs`（Playwright + Supermium），或 Tabbit |

"Web 版没有 IAB"是架构边界，不是 Win7 的 bug：

- Desktop 由 main 进程把 `browserControlPort` 注入给 Agent；
- Web 版的 Agent 是 `zcode.cjs app-server --stdio`，规格里**明确拒绝** app-server 另起 browser runtime
  （`docs/browser-use/2026-07-13-cli-headless-cdp-backend-spec.md`，HTTP 用例 `HCDP-003`）。

## 2. IAB（桌面版内置浏览器）

```text
模型 → control-browser 技能 → browser-client (node_repl)
     → browserControlPort（宿主注入）
     → BrowserGuestManager → guest.webContents.debugger (CDP 1.3)
     → DOM snapshot / Input / Page.captureScreenshot
```

- 渲染器用 `<webview partition="persist:zcode-embedded-browser">`，主进程 `debugger.attach` 后直接执行 CDP。
- 截图在**进程内**产生，不落盘；还能读 console/network、执行 `executeJavaScript`。
- **前提**：`resources\glm\packages\browser-use-plugin` 必须随包，否则模型没有
  `control-browser` 技能——表现为"能看到桥（`list` 通）但不会用"，转而调用 Tabbit。

排障看主进程日志里的 `[browser-use] execute … method=…`：
`list` / `listUserTabs` / `newTab` 成功只说明控制面通；要看到 `goto`/`snapshot` 才算真正跑通。
无交互桌面会话时会出现"webview 尚未就绪"、`BrowserGuestManager.closeTabDurably` 报错。

## 3. Playwright 方案（Web 版主力）

`tools/browser-verify.mjs`：用随包 `playwright-core` 拉起本机 Supermium（Chromium 150）。

```bat
C:\ZCode\runtime\node.exe tools\browser-verify.mjs http://127.0.0.1:8642/ ^
  --click "添加日程" --shot artifacts\calendar.png
```

返回 JSON：

```json
{
  "status": 200, "title": "简易日历", "browserVersion": "150.0.7871.255",
  "text": "首屏文本…", "clicks": [{"target": "添加日程", "ok": true}],
  "consoleErrors": [], "screenshot": "artifacts/calendar.png"
}
```

优点：一次调用完成 打开 → 点击 → 读文本 → 截图；不落盘中间态；可读 console 错误。
缺点：每次是新浏览器实例（无持久 profile），多步交互需要自己写脚本。

## 4. Tabbit 方案

- 技能：`%USERPROFILE%\.agents\skills\tabbit\SKILL.md`（用户级技能，不是 ZCode 内置）
- CLI：`%LOCALAPPDATA%\Tabbit\LocalAgent\bin\tabbit-cli.exe`

```bat
"%LOCALAPPDATA%\Tabbit\LocalAgent\bin\tabbit-cli.exe" nodejs --task "Read page" --request-id r1 < script.js
```

- JS 从 stdin 进，`return` 值进入 stdout JSON 的 `result.value`
- **截图是产物路径**（`result.nextAction.path`），需要再读一次文件；JPEG 不支持
- 已有页面用 `create` 看 inventory 再 `--tab`；结束要 `finish`

优点：浏览器版本可独立升级、与 ZCode 解耦。
缺点：跨进程、截图落盘、**看不到 Electron 内部**（无法替代 IAB 调试 ZCode 自身界面）。

## 5. 能不能用一个调试另一个

| 想做什么 | 正确做法 |
| --- | --- |
| 用 Tabbit 点 Electron 里的元素 | ❌ 不可能（不同进程、无 guest CDP） |
| 调试 Electron 应用 UI | ✅ `ZCode.exe --remote-debugging-port=9333` + CDP（`tools/desktop-ui-check.mjs`） |
| 调试 IAB 里的页面 | ✅ 走宿主 `BrowserGuestManager`（即 IAB 本身），或渲染器里的 `webview` API |
| 调试自己开发的 Web 页面 | ✅ `tools/browser-verify.mjs`（Web 版）/ IAB（桌面版） |

外部 CDP 能看到的只有 `page`（应用渲染器）、`iframe`（插件沙箱）、`worker`；
`<webview>` guest **不会**作为可直连目标出现。

## 6. 可切换策略（工作区约定）

`%USERPROFILE%\ZCodeWorkspace\AGENTS.md` 里定义了选择顺序（Agent 会读）：

1. 先判形态：标题 `ZCode - Web + Server` → Web 版；进程里有 `ZCode.exe` → 桌面版。
2. Web 版：`tools/browser-verify.mjs` → Tabbit。
3. 桌面版：IAB → `browser-verify.mjs` → Tabbit。
4. 同一任务不混用；不要用外部浏览器访问需要登录态的 ZCode 内部页面来替代 IAB。

## 7. 实测记录（Win7 SP1 x64）

| 项 | 结果 |
| --- | --- |
| Playwright 拉起 Supermium | ✅ `150.0.7871.255`，导航/点击/截图均成功 |
| IAB 控制面（桌面版） | ✅ `list` / `listUserTabs` / `newTab` 返回 ok |
| IAB guest 挂载（无桌面会话） | ❌ `<webview>` 未挂载，模型报"webview 尚未就绪" |
| Tabbit | ✅ 打开页面、读文本成功（截图为产物路径） |
| 外部 CDP 驱动应用 UI | ✅ `page` 目标可用，截图正常 |
