# 浏览器自动化后端：内置 IAB 与 Tabbit

## 1. 两个后端是什么

| 后端 | 本质 | 代码/资产位置 |
| --- | --- | --- |
| **IAB（内置浏览器）** | ZCode 自己窗口里的 `<webview>` guest，主进程用 `webContents.debugger.attach` 在**同进程**内执行 CDP | 渲染器 `UnifiedBrowserView`；主进程 `BrowserGuestManager`；模型侧入口是官方 `browser-use` 插件的 `control-browser` 技能与 `browser-client.mjs`（`resources/glm/packages/browser-use-plugin`） |
| **Tabbit** | 独立安装的 Chromium 分支进程，通过 `tabbit-cli` 接收 Playwright 代码 | 技能：`%USERPROFILE%\.agents\skills\tabbit\SKILL.md`；CLI：`%LOCALAPPDATA%\Tabbit\LocalAgent\bin\tabbit-cli.exe` |

注意：Tabbit 是**用户级技能**（`~/.agents/skills`），不属于 ZCode 内置插件；IAB 的桥由宿主注入，但**技能与 client 资产必须随包**，否则模型看得到桥却不知道怎么用
（本次组装桌面包时漏拷 `resources/glm/packages` 就出现过这种现象：`list` 能通，但模型不会调用）。

## 2. 结果与截图是怎么回来的

### 2.1 IAB

```text
模型 → control-browser 技能 → browser-client (node_repl)
     → browserControlPort (宿主注入)
     → 主进程 BrowserGuestManager → guest.webContents.debugger (CDP, 1.3)
     → snapshot 脚本 / Input 事件 / Page.captureScreenshot
```

- DOM 快照、点击、输入、截图全部在**主进程内部**完成，结果是结构化对象直接回给模型。
- 截图不需要落盘：`Page.captureScreenshot` 的 base64 由宿主转成图片结果。
- 同一个 guest 还能读 console、network、执行 `executeJavaScript`——这是"调试自己正在开发的页面"最需要的部分。

### 2.2 Tabbit

```text
模型 → Bash: tabbit-cli nodejs --task NAME --request-id ID  (stdin 传 Playwright JS)
     → Tabbit 浏览器进程
     → stdout JSON {"status":"succeeded","result":{"requestId","value":…}}
```

- `return` 的值成为 `result.value`，由 Bash 工具以文本形式回传；`tabbit.observe()` 用来拿无障碍树快照（有 `maxChars` 上限）。
- **截图是"产物路径"而不是图片数据**：`page.screenshot()` 返回带 `result.nextAction.path` 的 PNG 回执，
  模型必须再用读取文件的工具打开该路径，才能"看到"图片。JPEG 不支持。
- 因此一次视觉检查 = 两次往返（执行 + 读图），且中间经过磁盘。

## 3. 兼容性与数据链路对比

| 维度 | IAB | Tabbit |
| --- | --- | --- |
| 进程关系 | 同进程（Electron 主进程直连 guest CDP） | 跨进程（独立 Chromium） |
| 数据链路 | 内存内直传，无落盘 | stdout JSON + 截图落盘再读 |
| 能看到什么 | DOM、console、network、截图、`executeJavaScript` | 仅页面级 Playwright 能力 |
| 能否调试 ZCode 自身 UI | **能**（同一窗口的 webview） | **不能**（看不到 Electron 内部） |
| Chromium 版本 | 绑定 Electron（当前 146） | 可独立升级到新版 Chrome |
| Win7 适配成本 | 需要 Electron 补丁可用的环境 | 与 ZCode 解耦，只要 Tabbit 能跑 |
| 失败排查 | 看 `[browser-use] execute …` 主进程日志 | 看 CLI stdout/stderr 与任务名 |

结论：

- **数据传递"更扎实"的是 IAB**：同进程、少一次落盘、可读 console/network，适合调试自己正在开发的页面与 ZCode 自身界面。
- **Tabbit 的价值是解耦与浏览器版本**：当需要新版 Chrome 特性、或 IAB 在当前环境不可用时用它。
- 两者的"兼容性"不是同一维度：IAB 受宿主 Chromium 约束（Win7 上还叠加补丁风险），Tabbit 受独立浏览器约束但拿不到宿主内部信息。

## 4. 能否用 Tabbit 调试 IAB？

**不能。** Tabbit 驱动的是它自己的 Chromium 进程，没有 Electron guest 的 CDP 通道。

要调试"Electron 里的元素"，等价手段是 **CDP 直连 ZCode 应用本身**：

```text
ZCode.exe --remote-debugging-port=9333
任意 CDP 客户端（Playwright connectOverCDP / 自写 ws 客户端）
  → /json/list 拿到 page 目标
  → Runtime.evaluate 点击/读取、Page.captureScreenshot 截图
```

本次已用这种方式驱动桌面版 UI（点设置、发消息、截图）并成功。
但注意：`/json/list` 里只出现 `page`（应用渲染器）、`iframe`（插件沙箱）、`worker`，
**`<webview>` guest 不会作为可直连目标出现**；要操作 guest，只能走宿主自己的
`BrowserGuestManager`（也就是 IAB 那条路），或在渲染器里调用 `webview` 元素 API。

## 5. 可选项的落地方式

不修改产品代码，用**工作区约定**切换（已放在 `%USERPROFILE%\ZCodeWorkspace\AGENTS.md`）：

规则：

1. 先判断形态：窗口标题 `ZCode - Web + Server` 是 Web 版（**没有 IAB**）；进程里有
   `ZCode.exe` 是桌面版（有 IAB）。
2. Web 版优先用 `tools/browser-verify.mjs`（随包 `playwright-core` + 本机 Supermium，
   一次调用完成打开/点击/读文本/截图），Tabbit 作为备选；不得声称“没有浏览器后端”
   就停止。
3. 桌面版先走 IAB；若 guest 未挂载（无交互桌面会话时常见）再降级到上面的脚本。
4. 同一任务内不混用；需要换后端时新建任务。
5. 判定后端不可用前，先看日志区分“桥未注入 / 握手超时 / 页面报错”。

## 6. 当前在 Win7 上的验证状态

| 项 | 状态 |
| --- | --- |
| IAB 控制面（`list` / `listUserTabs` / `newTab`） | ✅ 主进程日志显示成功 |
| IAB guest 挂载（渲染器 `<webview>`） | ❌ 无交互桌面会话下未挂载：模型侧表现为"webview 尚未就绪"，随后停止 |
| IAB 关闭标签 | ⚠️ 报错 `BrowserGuestManager.closeTabDurably` |
| Tabbit 全链路 | ✅ 打开页面、读取文本正常（截图需二次读文件） |
| 外部 CDP 驱动应用 UI | ✅ `page` 目标可用，但看不到 guest |

因此：**在这台无交互桌面的 Win7 虚拟机上，IAB 暂不可用**（很可能与没有可见窗口/显示有关），
需要在一台真实登录桌面的 Win7 上复测；Tabbit 目前是 Win7 上的可用路径。

> 组装桌面包时的硬性要求：`resources\glm\packages` 必须包含官方插件
> （`browser-use-plugin` 等），否则模型没有 `control-browser` 技能，只会退回 Tabbit。
