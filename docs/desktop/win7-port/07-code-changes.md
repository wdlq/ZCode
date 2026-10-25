# 07 · 源码改动明细

本移植对仓库**只改了两处产品代码**，其余都是部署/打包层面。改动都带中文根因注释，
升级合并时请保留。

---

## 1. `scripts/build-zcode.mjs`

### 改动

```diff
-import { spawnSync } from "node:child_process";
+import { runCommand } from "./spawn-command.mjs";

 function run(command, args, options = {}) {
   console.log(`[zcode] ${commandText(command, args)}`);
-  const result = spawnSync(command, args, { cwd: root, stdio: "inherit", ...options });
-  if (result.error) throw new Error(...);
-  if (result.status !== 0) throw new Error(...);
+  // Windows 上 bare `pnpm` 由 cmd shim（pnpm.cmd）提供，spawnSync 直接执行只会查找
+  // .exe 并抛 ENOENT，导致 `pnpm build:zcode` 在 win32 上必然失败。
+  runCommand(command, args, { cwd: root, ...options });
 }
```

### 根因

Windows 的 `pnpm` 是 `pnpm.cmd` shim；`spawnSync("pnpm")` 不会解析 `.cmd`，直接 `ENOENT`。

### 为什么复用 `scripts/spawn-command.mjs`

该模块已经在仓库里处理了 Windows shim（`shell: true`）与含空格参数的引号问题，
并有注释记录了同类回归（`pnpm --dir` 路径被空格截断）。再写一份必然漂移。

### 影响面

- 只影响构建脚本 `pnpm build:zcode`，不进入任何运行时产物。
- `tar` 仍是真实 exe，走非 shell 分支，行为不变。

### 验证

- `pnpm build:zcode --base-url ...` 在 Windows 上可完整跑通（CLI → server → web → staging → tarball）。

---

## 2. `packages/services/src/project/index.ts`

### 改动 1：`route()`

```diff
 const route = async (hostId?: string) => {
   if (!hostId || hostId === (options.ownerHostId ?? "local")) return null;
+  // 普通 Web / ZCode Lite 的浏览器只有一个「此电脑」设备，客户端固定传 "local"；
+  // 而独立 Server 的持库 identity 是 remote:server:<id>，两者不是同一个 host。
+  // 没注入 resolveHost 就说明当前进程自己就持这套项目数据（desktop 的 local owner
+  // 或 standalone server），此时把 "local" 当作本进程 owner 做本地路由。
+  if (hostId === "local" && !options.resolveHost) return null;
   if (!options.resolveHost) throw new Error("project.host-offline");
   return options.resolveHost(hostId);
 };
```

### 改动 2：`saveProject()`

```diff
 const result = (await options.repository()).saveProject({
   ...input,
+  // 路由到本地后把 "local" 归一为本进程 owner，否则仓库层会判成跨 host 保存
+  // （project.host-immutable），Web 永远建不了项目。
+  hostId:
+    input.hostId === "local" && options.ownerHostId && options.ownerHostId !== "local"
+      ? options.ownerHostId
+      : input.hostId,
   roots,
   ...
 });
```

### 根因

`entry-http` 用 `createServerHostServices()` 装配服务，持库 host 是
`remote:server:<serverId>`（见 `packages/services/src/node.ts` 的 `projectStorageHostId`）。
而浏览器端只有「此电脑」一个设备，`packages/web` 固定传 `hostId: "local"`。于是：

| 位置 | 判断 | 结果 |
| --- | --- | --- |
| `route()` | `"local" !== ownerHostId` 且无 `resolveHost` | `project.host-offline`（目录浏览、建项目都失败） |
| `ProjectRepository.saveProject()` | `input.hostId("local") !== ownerHostId` | `project.host-immutable` |
| `assertRemoteTaskDirectories()` | owner 非 local 且无 project | `project.remote-project-required` |

### 边界与安全性

- 只在 **没有注入 `resolveHost`** 时生效——也就是"当前进程就是这套数据的 owner"
  （桌面 local owner / standalone server）。
- 桌面端行为不变：`ownerHostId` 为 `local`，且注入了 `resolveHost`。
- 远端约束不变：单 root、root 不可变、跨 host 拒绝仍由 `ownerHostId` 判定，
  **不因请求里的 `hostId` 放宽**。

### 影响面

- Web/Lite 形态：可以创建项目、打开目录选择器、创建会话。
- 桌面形态：无行为变化。
- 手机 `/remote` 走 shared-host，不受影响。

### 验证

- Web 版：创建项目 → 在项目下新建任务 → 发送消息成功。
- 桌面版：本地新建会话、Bash 工具调用均正常。

---

## 3. 非源码改动（部署与打包）

以下不修改产品代码，但属于本移植的交付物，按需提交或放在发布目录：

| 内容 | 位置 | 说明 |
| --- | --- | --- |
| Win7 启动器 | 安装包 `web\launcher\` | UTF-8 BOM；`Write-Status`；WMI 启动；残留自愈；`-LanAccess` |
| PE 补丁脚本 | 构建期使用 | 改 PE32+ 可选头 4 个 WORD（10.0 → 6.1） |
| VxKex 注册逻辑 | 启动器 + 安装器 | 按绝对路径匹配；安装器用路径哈希命名 |
| 桌面组装 | `resources\app` / `glm` / `config` | 见 03 |
| 离线安装器 | `install.ps1` / `install-core.ps1` / SFX | 见 05 |
| 浏览器工具 | `tools/browser-verify.mjs`、`desktop-ui-check.mjs` | 见 04 |
| 后端策略 | 工作区 `AGENTS.md` | 分形态选择浏览器后端 |

## 4. 升级合并检查清单

1. `scripts/build-zcode.mjs` 是否还在用本地 `spawnSync`？（若回退，Windows 构建会再坏）
2. `packages/services/src/project/index.ts` 的 `route()` / `saveProject()` 归一是否被覆盖？
3. `packages/desktop/package.json` 的 `electron` 是否还是 41.0.3？变了就要重新评估 PE 补丁与 VxKex。
4. `prepare:agent-bundle` 是否仍产出 `glm/packages/browser-use-plugin`？
5. 跑一次 `pnpm typecheck` / `pnpm lint` / `pnpm architecture:check --changed`，
   然后**重新构建 server** 再打包（见 05 踩坑 1）。
