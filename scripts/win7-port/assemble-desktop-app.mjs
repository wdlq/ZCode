#!/usr/bin/env node
// 组装桌面版的 resources\app（不含 Electron 运行时本身）。
//
// 用法：
//   node scripts/win7-port/assemble-desktop-app.mjs --target <dir> [--desktop-root <repo/packages/desktop>]
//
// 产出：
//   <target>/package.json   main = out/main/index.js, type = module
//   <target>/out            main / host / preload / renderer / scheduler / plugin-sandbox
//   <target>/bundled-agents 开发态回退用（打包态走 resources\glm）
//   <target>/build, native  图标等资源
//   <target>/node_modules   主/宿主进程的运行时依赖闭包
//
// 依赖收集规则（与 packaging 侧保持一致）：
//   - 取 packages/desktop/package.json 的 dependencies；
//   - 排除 @zcode/*（已被 tsup 内联）、react / react-dom（只服务渲染器）；
//   - 递归复制每个包的 dependencies + optionalDependencies（dereference，展开 pnpm symlink）。
//
// 注意：electron-builder 会被本项目大量原生资产校验钩子阻断，Win7 移植采用手工组装。
import { cp, mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";

const repoRoot = resolve(import.meta.dirname, "../..");
const readFlag = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
};

const desktopRoot = resolve(readFlag("desktop-root", join(repoRoot, "packages/desktop")));
const targetRoot = resolve(readFlag("target", join(repoRoot, "dist/win7-desktop-app")));
const requireFromDesktop = createRequire(join(desktopRoot, "package.json"));

const EXCLUDED = new Set(["electron", "react", "react-dom"]);

async function resolvePackageJson(fromRequire, packageName) {
  try {
    return fromRequire.resolve(`${packageName}/package.json`);
  } catch (error) {
    if (error?.code !== "ERR_PACKAGE_PATH_NOT_EXPORTED") throw error;
    let current = dirname(fromRequire.resolve(packageName));
    for (;;) {
      const candidate = join(current, "package.json");
      const exists = await stat(candidate).then((value) => value.isFile()).catch(() => false);
      if (exists) {
        const manifest = JSON.parse(await readFile(candidate, "utf8"));
        if (manifest.name === packageName) return candidate;
      }
      const parent = dirname(current);
      if (parent === current) throw error;
      current = parent;
    }
  }
}

const copied = new Set();
async function copyPackageTree(packageName, fromRequire) {
  if (copied.has(packageName)) return;
  copied.add(packageName);
  let packageJsonPath;
  try {
    packageJsonPath = await resolvePackageJson(fromRequire, packageName);
  } catch {
    console.warn(`[assemble] missing package: ${packageName}`);
    return;
  }
  const packageDir = dirname(packageJsonPath);
  const destination = join(targetRoot, "node_modules", ...packageName.split("/"));
  await mkdir(dirname(destination), { recursive: true });
  await cp(packageDir, destination, {
    recursive: true,
    dereference: true,
    force: true,
    filter: (source) => !source.includes(`${join("node_modules", ".cache")}`),
  });
  const manifest = JSON.parse(await readFile(packageJsonPath, "utf8"));
  const childRequire = createRequire(packageJsonPath);
  for (const dependency of Object.keys({ ...manifest.dependencies, ...manifest.optionalDependencies })) {
    try {
      await copyPackageTree(dependency, childRequire);
    } catch (error) {
      if (!manifest.optionalDependencies?.[dependency]) {
        console.warn(`[assemble] skip ${dependency}: ${error.message}`);
      }
    }
  }
}

await mkdir(targetRoot, { recursive: true });
const desktopManifest = JSON.parse(await readFile(join(desktopRoot, "package.json"), "utf8"));
await writeFile(
  join(targetRoot, "package.json"),
  JSON.stringify(
    {
      name: desktopManifest.name,
      productName: desktopManifest.productName,
      version: desktopManifest.version ?? "0.0.0",
      type: "module",
      main: desktopManifest.main,
      description: desktopManifest.description,
    },
    null,
    2,
  ),
);

for (const dir of ["out", "bundled-agents", "build", "native"]) {
  await cp(join(desktopRoot, dir), join(targetRoot, dir), {
    recursive: true,
    dereference: true,
    force: true,
  }).catch((error) => console.warn(`[assemble] skip ${dir}: ${error.message}`));
}

const dependencies = Object.keys(desktopManifest.dependencies ?? {}).filter(
  (name) => !EXCLUDED.has(name) && !name.startsWith("@zcode/"),
);
console.log(`[assemble] runtime dependencies (${dependencies.length})`);
for (const name of dependencies) await copyPackageTree(name, requireFromDesktop);
console.log(`[assemble] done: ${targetRoot}`);
