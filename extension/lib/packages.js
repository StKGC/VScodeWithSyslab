/*---------------------------------------------------------------------------------------------
 *  读取 Syslab 默认 Julia 环境里可用的包列表（供「选择预加载包」使用）
 *
 *  纯 Node 实现（不依赖 vscode），便于单独测试。
 *--------------------------------------------------------------------------------------------*/
'use strict';

const fs = require('fs');
const path = require('path');

/** 解析 Project.toml 的 [deps] 段，返回包名数组 */
function parseDepsSection(tomlText) {
    const names = [];
    let inDeps = false;
    for (const raw of String(tomlText).split(/\r?\n/)) {
        const line = raw.trim();
        if (!line || line.startsWith('#')) { continue; }
        if (line.startsWith('[')) {
            inDeps = /^\[\s*deps\s*\]$/i.test(line);
            continue;
        }
        if (!inDeps) { continue; }
        const match = /^([A-Za-z0-9_]+)\s*=\s*"/.exec(line);
        if (match) { names.push(match[1]); }
    }
    return names;
}

/** 解析 Manifest.toml 的 [[deps.X]] 块，返回 { 包名: 版本 } */
function parseManifestVersions(tomlText) {
    const versions = {};
    let current = null;
    for (const raw of String(tomlText).split(/\r?\n/)) {
        const line = raw.trim();
        if (!line || line.startsWith('#')) { continue; }
        const block = /^\[\[deps\.([A-Za-z0-9_]+)\]\]$/.exec(line);
        if (block) { current = block[1]; continue; }
        if (line.startsWith('[')) { current = null; continue; }
        if (!current) { continue; }
        const match = /^version\s*=\s*"([^"]+)"/.exec(line);
        if (match) { versions[current] = match[1]; }
    }
    return versions;
}

/** Julia 标准库（无需安装即可 using，常被一起预加载） */
const STDLIB_PACKAGES = [
    'LinearAlgebra', 'SparseArrays', 'Statistics', 'Printf', 'Random',
    'Dates', 'Distributed', 'Test'
];

/**
 * 列出环境里可预加载的包。
 * @param {string} projectPath  Project.toml 路径（Syslab 默认环境）
 * @param {string} manifestPath Manifest.toml 路径（可选，用于显示版本）
 * @returns {{name:string, version:string, stdlib:boolean}[]}
 */
function listEnvironmentPackages(projectPath, manifestPath) {
    let deps = [];
    try {
        if (projectPath && fs.existsSync(projectPath)) {
            deps = parseDepsSection(fs.readFileSync(projectPath, 'utf8'));
        }
    } catch (err) { /* 忽略，返回空列表 */ }

    let versions = {};
    try {
        if (manifestPath && fs.existsSync(manifestPath)) {
            versions = parseManifestVersions(fs.readFileSync(manifestPath, 'utf8'));
        }
    } catch (err) { /* 忽略 */ }

    const seen = new Set();
    const result = [];
    for (const name of deps) {
        if (seen.has(name)) { continue; }
        seen.add(name);
        result.push({ name, version: versions[name] || '', stdlib: false });
    }
    for (const name of STDLIB_PACKAGES) {
        if (seen.has(name)) { continue; }
        seen.add(name);
        result.push({ name, version: versions[name] || '', stdlib: true });
    }
    result.sort((a, b) => a.name.localeCompare(b.name));
    return result;
}

/** 默认环境路径（Project.toml / Manifest.toml） */
function defaultEnvironmentFiles(depotPath, juliaVersion) {
    const match = /(\d+)\.(\d+)/.exec(String(juliaVersion || ''));
    const envName = match ? `v${match[1]}.${match[2]}` : null;
    if (!envName) { return { projectPath: null, manifestPath: null }; }
    const dir = path.join(String(depotPath).replace(/[\\/]+$/, ''), 'environments', envName);
    return {
        projectPath: path.join(dir, 'Project.toml'),
        manifestPath: path.join(dir, 'Manifest.toml')
    };
}

module.exports = {
    parseDepsSection,
    parseManifestVersions,
    listEnvironmentPackages,
    defaultEnvironmentFiles,
    STDLIB_PACKAGES
};
