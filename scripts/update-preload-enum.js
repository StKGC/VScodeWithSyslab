/*---------------------------------------------------------------------------------------------
 *  按本机 Syslab 环境刷新「预加载包」下拉候选（enum）
 *
 *  直接改的是**已安装扩展**的 package.json：把 contributes.configuration.properties
 *  .syslab.preloadPackages.items.enum 替换成当前环境真实可用的包列表（默认环境 [deps] + 常用标准库）。
 *  这样设置页的下拉里只会出现本机真的能 `using` 的包。
 *
 *  用法（由 install.ps1 调用，也可单独执行）：
 *    node update-preload-enum.js <已安装扩展的 package.json> <Project.toml> <Manifest.toml> [--dry-run]
 *--------------------------------------------------------------------------------------------*/
'use strict';

const fs = require('fs');
const path = require('path');

const packagesLib = require(path.join(__dirname, '..', 'extension', 'lib', 'packages.js'));

function main() {
    const args = process.argv.slice(2).filter(a => a !== '--dry-run');
    const dryRun = process.argv.includes('--dry-run');
    const [pkgPath, projectPath, manifestPath] = args;

    if (!pkgPath) {
        console.error('用法: node update-preload-enum.js <package.json> <Project.toml> <Manifest.toml> [--dry-run]');
        process.exit(2);
    }
    if (!fs.existsSync(pkgPath)) {
        console.error('找不到扩展清单: ' + pkgPath);
        process.exit(2);
    }

    const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8').replace(/^\uFEFF/, ''));
    const properties = pkg.contributes && pkg.contributes.configuration &&
        pkg.contributes.configuration.properties;
    const setting = properties && properties['syslab.preloadPackages'];
    if (!setting || !setting.items) {
        console.error('该清单里没有 syslab.preloadPackages.items，跳过');
        process.exit(3);
    }

    const discovered = packagesLib.listEnvironmentPackages(projectPath, manifestPath);
    if (discovered.length === 0) {
        console.error('未从环境里读到任何包（Project.toml 路径: ' + projectPath + '），保持原候选不变');
        process.exit(4);
    }

    const names = Array.from(new Set(discovered.map(p => p.name))).sort((a, b) => a.localeCompare(b));
    // 默认值必须在候选列表里，否则设置页会报“值不在允许范围内”
    for (const fallback of (setting.default || [])) {
        if (!names.includes(fallback)) { names.push(fallback); }
    }

    const before = (setting.items.enum || []).length;
    setting.items.enum = names;
    if (dryRun) {
        console.log(`[dry-run] 候选 ${before} -> ${names.length}：${names.slice(0, 12).join(', ')} ...`);
        return;
    }
    fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n', { encoding: 'utf8' });
    console.log(`已刷新预加载候选：${before} -> ${names.length} 个（${names.slice(0, 8).join(', ')} ...）`);
}

main();
