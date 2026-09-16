/*---------------------------------------------------------------------------------------------
 *  MWORKS Syslab Bridge —— 在原生 VS Code 中使用 MWORKS.Syslab 的 Julia / M 语言环境
 *
 *  设计目标：
 *   1. 与 Syslab 主程序（out/syslab-environment-win32.js）使用完全一致的环境变量；
 *   2. 即使不是通过 Syslab 启动器打开 VS Code，也能在终端里拿到 Syslab 环境；
 *   3. 提供运行脚本 / REPL / 用 Syslab 打开 / 环境自检 等命令，作为 Syslab 自带扩展的补充。
 *--------------------------------------------------------------------------------------------*/
'use strict';

const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');
const cp = require('child_process');

const ENV_FILE_DEFAULT = path.join(os.homedir(), '.syslab-vscode', 'env.json');
const CANDIDATE_ROOTS = [
    'D:\\Math\\MWORKS\\Syslab',
    'C:\\Math\\MWORKS\\Syslab',
    'D:\\MWORKS\\Syslab',
    'C:\\MWORKS\\Syslab',
    'D:\\Program Files\\MWORKS\\Syslab',
    'C:\\Program Files\\MWORKS\\Syslab'
];

/** @type {any} */
let cachedEnv = null;
let outputChannel = null;
let statusBarItem = null;
/** @type {vscode.Terminal|null} */
let replTerminal = null;

/**
 * Syslab 外壳（Syslab 主程序内建）提供的命令。这些命令在原生 VS Code 中并不存在，
 * 而 Syslab 的 Julia / TyMLang / APP Designer 扩展会在 activate 阶段直接调用它们；
 * 缺少时扩展会激活失败。这里为“确实不存在且没有被任何已装扩展贡献”的命令注册空实现，
 * 让扩展能够完成激活（相关高级功能自然降级，但编辑/运行/调试/REPL 等主流程可用）。
 */
const SYSLAB_SHELL_COMMANDS = [
    'Syslab.getAccountAndDevice', 'Syslab.getContext', 'Syslab.getMachineId', 'Syslab.getProductInfo',
    'Syslab.getReconnectionToken', 'Syslab.getUserConfig', 'Syslab.getUserInfo', 'Syslab.getWindowLocationInfo',
    'Syslab.isStartDebug', 'Syslab.registerWhiteList', 'Syslab.workPath.goLastPath',
    'SyslabOnline.closeAllJuliaPlot', 'SyslabOnline.get-user-id', 'SyslabOnline.get-webagg-port',
    'SyslabOnline.onDebugExit',
    'syslab.changeWorkPath', 'syslab.changeWorkspace', 'syslab.closeDialog',
    'syslab.closeMemoryLimitWarning', 'syslab.closeREPLMemoryLimitWarning', 'syslab.debug.setIsDebugRunning',
    'syslab.dialog.create', 'syslab.dialog.postMessage', 'syslab.drawTableMap', 'syslab.example.install',
    'syslab.execSyslabStartSysplorer', 'syslab.getCurrentWaitbarId',
    'syslab.getMapTableNewWindow', 'syslab.getNativeWindowHandle',
    'syslab.getWorkPathDefault', 'syslab.julia.applyWorkspaceEditWithPreview', 'syslab.license.checkFeature',
    'syslab.license.getLicenseServerInfo', 'syslab.newJuliaObjectFile',
    'syslab.nss.dialogWindow', 'syslab.open.help', 'syslab.open.url', 'syslab.openApp',
    'syslab.openAppDesigner', 'syslab.openDialog', 'syslab.openSettingsJson',
    'syslab.postMessage.devMate', 'syslab.postMessageToApp', 'syslab.recent.list', 'syslab.recent.open',
    'syslab.refreshAppList', 'syslab.releaseNotes.open', 'syslab.render.markdown',
    'syslab.repl.getWorkPathQueueLength', 'syslab.repl.ifQueueChangePath', 'syslab.repl.updateWorkPath',
    'syslab.script.create', 'syslab.sendRibbontrackInfo', 'syslab.sendtrackInfo', 'syslab.showMemoryLimitWarning',
    'syslab.showREPLMemoryLimitWarning', 'syslab.status.fileRunning', 'syslab.status.setAppRunningStatus',
    'syslab.status.setRunningStatus', 'syslab.terminal.getCachedData', 'syslab.toggleHistoryVisibility',
    'syslab.toggleSyslabWelcom', 'syslab.UnInstallApp', 'syslab.updateDebugView', 'syslab.updateIsShowOnStart',
    'syslab.updateLastCheckTime', 'syslab.workbench.dialog.open', 'syslab.workbench.dialog.postMessage',
    'syslab.workbench.dialog.update',
    'vscode.activeClearMLangWorkspaceConfirmDialog', 'vscode.activeClearWorkspaceConfirmDialog',
    'vscode.activeRibbonButton', 'vscode.activeSystemImageDialog', 'vscode.activebuildProjectConfirmDialog',
    'vscode.deactivateRibbonButton', 'vscode.getSyslabRootName', 'vscode.handleSyslabExtensionFinished',
    'vscode.openConfirmDialog'
];

async function registerShellCommandStubs(context) {    const contributed = new Set();
    for (const extension of vscode.extensions.all) {
        const commands = extension.packageJSON && extension.packageJSON.contributes &&
            extension.packageJSON.contributes.commands;
        if (!Array.isArray(commands)) { continue; }
        for (const item of commands) {
            const id = typeof item === 'string' ? item : (item && item.command);
            if (id) { contributed.add(id); }
        }
    }

    let existing = new Set();
    try {
        existing = new Set(await vscode.commands.getCommands(true));
    } catch (err) { /* 忽略 */ }

    let registered = 0;
    for (const id of SYSLAB_SHELL_COMMANDS) {
        if (contributed.has(id) || existing.has(id)) { continue; }
        try {
            context.subscriptions.push(vscode.commands.registerCommand(id, function () {
                return undefined;
            }));
            registered++;
        } catch (err) { /* 已被占用则跳过 */ }
    }
    return registered;
}

/* -------------------------------------------------------------------------- */
/* 环境解析                                                                    */
/* -------------------------------------------------------------------------- */

function toFwd(p) {
    return String(p).replace(/\\/g, '/').replace(/\/+$/, '');
}

function readProductInfo(syslabHome) {
    const productPath = path.join(syslabHome, 'Bin', 'resources', 'app', 'product.json');
    if (!fs.existsSync(productPath)) {
        return null;
    }
    try {
        const product = JSON.parse(fs.readFileSync(productPath, 'utf8'));
        return {
            syslabHome: syslabHome,
            tongYuanPath: toFwd(product.syslabUserDataPath || 'C:/Users/Public/TongYuan'),
            juliaVersion: product.juliaVersion || 'julia-1.10.10',
            syslabVersion: product.syslabVersion || '',
            cachePath: toFwd(product.syslabCachePath || ''),
            title: product.syslabTitleName || 'MWORKS.Syslab'
        };
    } catch (err) {
        return null;
    }
}

function findSyslabHome() {
    const candidates = [];
    if (process.env.SYSLAB_HOME) {
        candidates.push(process.env.SYSLAB_HOME);
    }
    for (const root of CANDIDATE_ROOTS) {
        try {
            if (!fs.existsSync(root)) { continue; }
            for (const entry of fs.readdirSync(root)) {
                if (/^Syslab/i.test(entry)) {
                    candidates.push(path.join(root, entry));
                }
            }
        } catch (err) { /* 忽略无权限目录 */ }
    }
    for (const candidate of candidates) {
        if (candidate && fs.existsSync(path.join(candidate, 'Bin', 'resources', 'app', 'product.json'))) {
            return candidate;
        }
    }
    return null;
}

function pathExists(p) {
    try { return !!p && fs.existsSync(p); } catch (err) { return false; }
}

function buildEnvValues(info) {
    const juliaHome = `${info.tongYuanPath}/${info.juliaVersion}`;
    const depot = `${info.tongYuanPath}/.julia`;
    const conda3 = `${depot}/miniforge3`;
    const parts = [
        `${juliaHome}/bin`,
        `${juliaHome}/lib`,
        `${juliaHome}/lib/julia`,
        `${info.syslabHome}/Tools/Git/cmd`,
        `${info.syslabHome}/Tools/Git/usr/bin`,
        `${info.syslabHome}/Tools/Git/mingw64/bin`,
        `${info.syslabHome}/Tools/PortableGit/cmd`,
        `${info.syslabHome}/Tools/PortableGit/usr/bin`,
        `${info.syslabHome}/Tools/SyslabCC`,
        `${info.syslabHome}/Tools/zig`,
        `${info.syslabHome}/Tools/TyMLangDist`
    ].filter(pathExists);

    if (pathExists(conda3)) {
        for (const p of [
            conda3,
            `${conda3}/Library/mingw-w64/bin`,
            `${conda3}/Library/usr/bin`,
            `${conda3}/Library/bin`,
            `${conda3}/Scripts`,
            `${conda3}/bin`
        ]) {
            if (pathExists(p)) { parts.push(p); }
        }
    }
    parts.push(process.env.PATH || '');

    return {
        SYSLAB_HOME: info.syslabHome,
        TONGYUAN_PATH: info.tongYuanPath,
        JULIA_HOME: juliaHome,
        SYSLAB_JULIA_PATH: `${info.tongYuanPath}/syslab-julia`,
        JULIA_DEPOT_PATH: depot,
        PATH: parts.join(';'),
        PYTHON: `${conda3}/python.exe`,
        PYTHONNOUSERSITE: '1',
        KMP_DUPLICATE_LIB_OK: 'TRUE',
        JULIA_CONDAPKG_BACKEND: 'Null',
        PYTHON_JULIAPKG_OFFLINE: 'yes',
        JULIA_PYTHONCALL_EXE: '@PyCall',
        TYPY_JL_EXE: `${juliaHome}/bin/julia.exe`,
        BITANSWER_ROOT_PATH: info.cachePath,
        JULIA_PKG_PRESERVE_TIERED_INSTALLED: 'true',
        SYSLAB_VERSION: info.syslabVersion,
        TYPLOT_INTERACTIVE: 'true',
        JULIA_USE_FLISP_PARSER: '1'
    };
}

function envFilePath() {
    const configured = vscode.workspace.getConfiguration('syslab').get('envFile');
    if (configured) {
        return configured.replace(/^~/, os.homedir());
    }
    return ENV_FILE_DEFAULT;
}

/**
 * 解析 Syslab 环境：优先使用 install.ps1 生成的 env.json，其次自行探测。
 */
function resolveSyslab(force) {
    if (cachedEnv && !force) { return cachedEnv; }

    const file = envFilePath();
    if (fs.existsSync(file)) {
        try {
            // 兼容带 BOM 的 UTF-8 文件（Windows PowerShell 5.1 的 Set-Content 会写 BOM）
            const raw = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
            const values = raw.values || raw.Values || raw;
            const info = {
                syslabHome: raw.syslabHome || values.SYSLAB_HOME,
                tongYuanPath: toFwd(raw.tongYuanPath || values.TONGYUAN_PATH || ''),
                juliaVersion: raw.juliaVersion || path.basename(toFwd(values.JULIA_HOME || '')),
                syslabVersion: raw.syslabVersion || values.SYSLAB_VERSION || '',
                title: raw.title || 'MWORKS.Syslab',
                source: file
            };
            cachedEnv = finalizeEnv(info, values);
            return cachedEnv;
        } catch (err) {
            if (outputChannel) {
                outputChannel.appendLine(`[警告] 读取 ${file} 失败：${err.message}，改为自动探测。`);
            }
        }
    }

    const home = findSyslabHome();
    if (!home) { return null; }
    const info = readProductInfo(home);
    if (!info) { return null; }
    info.source = '自动探测';
    cachedEnv = finalizeEnv(info, buildEnvValues(info));
    return cachedEnv;
}

function finalizeEnv(info, values) {
    const juliaVersionMatch = /(\d+)\.(\d+)/.exec(info.juliaVersion || '');
    const defaultProject = juliaVersionMatch
        ? `${toFwd(values.JULIA_DEPOT_PATH)}/environments/v${juliaVersionMatch[1]}.${juliaVersionMatch[2]}`
        : toFwd(values.JULIA_DEPOT_PATH);

    const configuredJulia = vscode.workspace.getConfiguration('syslab').get('juliaExecutable');
    const juliaExe = configuredJulia || `${toFwd(values.JULIA_HOME)}/bin/julia.exe`;

    const configuredSyslabExe = vscode.workspace.getConfiguration('syslab').get('syslabExecutable');
    const syslabExe = configuredSyslabExe || (info.syslabHome ? path.join(info.syslabHome, 'Bin', 'syslab.exe') : '');

    return {
        info: info,
        values: values,
        juliaExe: juliaExe,
        juliaHome: toFwd(values.JULIA_HOME),
        depot: toFwd(values.JULIA_DEPOT_PATH),
        defaultProject: defaultProject,
        syslabExe: syslabExe,
        available: pathExists(juliaExe)
    };
}

function projectPath(env) {
    const cfg = vscode.workspace.getConfiguration('syslab');
    if (cfg.get('repl.envMode') === 'project') {
        const folder = vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders[0];
        if (folder && fs.existsSync(path.join(folder.uri.fsPath, 'Project.toml'))) {
            return folder.uri.fsPath;
        }
    }
    const configured = cfg.get('projectPath');
    if (configured) { return configured; }
    return env.defaultProject;
}

function preloadPackages() {
    const pkgs = vscode.workspace.getConfiguration('syslab').get('preloadPackages') || [];
    return pkgs.filter(p => !!p);
}

/* -------------------------------------------------------------------------- */
/* 终端                                                                        */
/* -------------------------------------------------------------------------- */

function terminalEnv(env) {
    const out = {};
    for (const key of Object.keys(env.values)) {
        out[key] = String(env.values[key]);
    }
    return out;
}

function requireEnv() {
    const env = resolveSyslab(false);
    if (!env || !env.available) {
        vscode.window.showErrorMessage(
            '未找到可用的 MWORKS Syslab Julia 运行时。请先运行本工具包的 install.ps1，或设置 syslab.juliaExecutable。',
            '显示环境信息'
        ).then(choice => {
            if (choice === '显示环境信息') { vscode.commands.executeCommand('syslab.showEnvironment'); }
        });
        return null;
    }
    return env;
}

function workspaceCwd() {
    const editor = vscode.window.activeTextEditor;
    if (editor && editor.document.uri.scheme === 'file') {
        return path.dirname(editor.document.uri.fsPath);
    }
    const folder = vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders[0];
    return folder ? folder.uri.fsPath : os.homedir();
}

function createJuliaTerminal(name, args, env, cwd) {
    return vscode.window.createTerminal({
        name: name,
        shellPath: env.juliaExe,
        shellArgs: args,
        cwd: cwd,
        env: terminalEnv(env),
        iconPath: new vscode.ThemeIcon('beaker')
    });
}

function getReplTerminal(env, reveal) {
    const alive = replTerminal && replTerminal.exitStatus === undefined;
    if (!alive) {
        const args = [`--project=${projectPath(env)}`, '-i', '--banner=no'];
        const pkgs = preloadPackages();
        if (pkgs.length) {
            args.push('-e', `using ${pkgs.join(', ')}`);
        }
        replTerminal = createJuliaTerminal('Syslab Julia REPL', args, env, workspaceCwd());
    }
    if (reveal !== false) {
        replTerminal.show(true);
    }
    return replTerminal;
}

/* -------------------------------------------------------------------------- */
/* 运行逻辑                                                                    */
/* -------------------------------------------------------------------------- */

function isMLang(document) {
    const lang = document.languageId;
    const ext = path.extname(document.uri.fsPath || '').toLowerCase();
    return lang === 'mlang' || ext === '.m' || ext === '.tym';
}

function activeFileDocument() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
        vscode.window.showWarningMessage('当前没有打开的文件。');
        return null;
    }
    if (editor.document.uri.scheme !== 'file') {
        vscode.window.showWarningMessage('请先保存文件后再运行。');
        return null;
    }
    return editor.document;
}

async function runFile() {
    const document = activeFileDocument();
    if (!document) { return; }
    if (isMLang(document)) {
        return runMLang(document, 'file');
    }
    const env = requireEnv();
    if (!env) { return; }
    if (document.isDirty) { await document.save(); }

    const file = document.uri.fsPath;
    const args = [`--project=${projectPath(env)}`, file];
    const terminal = createJuliaTerminal(`Syslab: ${path.basename(file)}`, args, env, path.dirname(file));
    terminal.show(true);
}

async function runFileInREPL() {
    const document = activeFileDocument();
    if (!document) { return; }
    if (isMLang(document)) {
        return runMLang(document, 'repl');
    }
    const env = requireEnv();
    if (!env) { return; }
    if (document.isDirty) { await document.save(); }

    const terminal = getReplTerminal(env, true);
    const juliaPath = toFwd(document.uri.fsPath);
    terminal.sendText(`include("${juliaPath}")`);
}

async function runSelection() {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
        vscode.window.showWarningMessage('当前没有打开的编辑器。');
        return;
    }
    const code = editor.document.getText(editor.selection);
    if (!code.trim()) {
        vscode.window.showWarningMessage('没有选中任何代码。');
        return;
    }
    if (isMLang(editor.document)) {
        return runMLang(editor.document, 'selection', code);
    }
    const env = requireEnv();
    if (!env) { return; }
    const terminal = getReplTerminal(env, true);
    for (const line of code.split(/\r?\n/)) {
        terminal.sendText(line);
    }
}

async function runMLang(document, mode, code) {
    // M 语言（.m/.tym）由 Syslab 的 TyMLangIDE 扩展负责执行；这里做命令转发。
    const commands = await vscode.commands.getCommands(true);
    if (commands.indexOf('tymlang.executeFileByUrl') >= 0) {
        if (mode === 'selection' && code) {
            vscode.window.showInformationMessage('M 语言暂不支持运行选区，已改为运行整个文件。');
        }
        if (document.isDirty) { await document.save(); }
        await vscode.commands.executeCommand('tymlang.executeFileByUrl', document.uri.toString());
        return;
    }
    if (commands.indexOf('language-julia.executeActiveFile') >= 0) {
        await vscode.commands.executeCommand('language-julia.executeActiveFile');
        return;
    }
    vscode.window.showWarningMessage(
        '未检测到 Syslab 的 M 语言（TyMLangIDE）扩展，无法运行 .m 脚本。请先运行 install.ps1 安装 Syslab 扩展。'
    );
}

function startREPL() {
    const env = requireEnv();
    if (!env) { return; }
    getReplTerminal(env, true);
}

function stopREPL() {
    if (replTerminal && replTerminal.exitStatus === undefined) {
        replTerminal.dispose();
        replTerminal = null;
        vscode.window.showInformationMessage('已关闭 Syslab Julia REPL。');
    }
}

function openInSyslab() {
    const document = activeFileDocument();
    if (!document) { return; }
    const env = resolveSyslab(false);
    if (!env || !env.syslabExe || !pathExists(env.syslabExe)) {
        vscode.window.showErrorMessage('未找到 MWORKS Syslab 主程序（Syslab.exe）。');
        return;
    }
    try {
        cp.spawn(env.syslabExe, [document.uri.fsPath], {
            detached: true,
            stdio: 'ignore',
            cwd: path.dirname(document.uri.fsPath)
        }).unref();
        vscode.window.showInformationMessage(`已用 MWORKS Syslab 打开 ${path.basename(document.uri.fsPath)}`);
    } catch (err) {
        vscode.window.showErrorMessage(`启动 Syslab 失败：${err.message}`);
    }
}

/* -------------------------------------------------------------------------- */
/* 环境展示 / 自检                                                             */
/* -------------------------------------------------------------------------- */

function getOutputChannel() {
    if (!outputChannel) {
        outputChannel = vscode.window.createOutputChannel('MWORKS Syslab');
    }
    return outputChannel;
}

async function showEnvironment() {
    const channel = getOutputChannel();
    channel.clear();
    channel.appendLine('=== MWORKS Syslab Bridge / 环境信息 ===');
    const env = resolveSyslab(true);
    if (!env) {
        channel.appendLine('未找到 Syslab 安装，请运行 install.ps1 或设置 syslab.envFile。');
        channel.show(true);
        return;
    }
    channel.appendLine(`来源          : ${env.info.source}`);
    channel.appendLine(`Syslab 版本   : ${env.info.title || ''} ${env.info.syslabVersion || ''}`);
    channel.appendLine(`安装目录      : ${env.info.syslabHome}`);
    channel.appendLine(`TONGYUAN_PATH : ${env.info.tongYuanPath}`);
    channel.appendLine(`Julia         : ${env.juliaExe}`);
    channel.appendLine(`Julia Depot   : ${env.depot}`);
    channel.appendLine(`默认环境      : ${env.defaultProject}`);
    channel.appendLine(`Syslab.exe    : ${env.syslabExe}`);
    channel.appendLine('');
    channel.appendLine('--- 环境变量 ---');
    for (const key of Object.keys(env.values)) {
        if (key === 'PATH') { continue; }
        channel.appendLine(`${key} = ${env.values[key]}`);
    }
    channel.appendLine('');
    channel.appendLine('--- 文件检查 ---');
    const checks = [
        [env.juliaExe, 'julia.exe'],
        [`${env.depot}/environments`, 'Depot 环境目录'],
        [`${env.depot}/packages/TyBase`, 'TyBase 包'],
        [`${env.depot}/packages/TyPlot`, 'TyPlot 包']
    ];
    for (const [p, label] of checks) {
        channel.appendLine(`${pathExists(p) ? '[OK]  ' : '[缺失]'} ${label}: ${p}`);
    }
    channel.appendLine('');
    channel.appendLine('正在查询 Julia 版本 ...');
    channel.show(true);

    try {
        const out = await new Promise((resolve, reject) => {
            cp.execFile(env.juliaExe, [`--project=${env.defaultProject}`, '-e', 'println(VERSION); println(Base.active_project())'],
                { env: Object.assign({}, process.env, terminalEnv(env)), timeout: 60000 },
                (err, stdout, stderr) => err ? reject(new Error(stderr || err.message)) : resolve(stdout));
        });
        channel.appendLine(out.trim());
        channel.appendLine('Julia 运行时可用 ✓');
    } catch (err) {
        channel.appendLine(`Julia 运行时调用失败：${err.message}`);
    }
}

function checkHealth() {
    const env = requireEnv();
    if (!env) { return; }
    const pkgs = preloadPackages();
    const script = [
        'println("Julia 版本      : ", VERSION)',
        'println("活跃环境       : ", Base.active_project())',
        'println("Depot          : ", DEPOT_PATH[1])',
        'println("Syslab 版本    : ", get(ENV, "SYSLAB_VERSION", "-"))'
    ];
    if (pkgs.length) {
        script.push(`using ${pkgs.join(', ')}`);
        script.push(`println("预加载包       : ${pkgs.join(', ')} ✓")`);
    }
    script.push('println("Syslab 环境自检通过 ✓")');

    // 写成临时脚本再运行：避免把带引号的代码塞进命令行（Windows 下会被二次解析）
    const checkFile = path.join(os.tmpdir(), 'syslab-health-check.jl');
    try {
        fs.writeFileSync(checkFile, script.join('\n') + '\n', 'utf8');
    } catch (err) {
        vscode.window.showErrorMessage(`无法写入自检脚本：${err.message}`);
        return;
    }
    const args = [`--project=${projectPath(env)}`, checkFile];
    const terminal = createJuliaTerminal('Syslab 自检', args, env, workspaceCwd());
    terminal.show(true);
}

function openFolder(p) {
    if (!p || !pathExists(p)) {
        vscode.window.showWarningMessage(`目录不存在：${p}`);
        return;
    }
    vscode.commands.executeCommand('revealFileInOS', vscode.Uri.file(p));
}

/* -------------------------------------------------------------------------- */
/* 激活                                                                        */
/* -------------------------------------------------------------------------- */

function updateStatusBar() {
    if (!statusBarItem) {
        statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 90);
        statusBarItem.command = 'syslab.showEnvironment';
    }
    const env = resolveSyslab(false);
    if (!env || !env.available) {
        statusBarItem.text = '$(beaker) Syslab 未就绪';
        statusBarItem.tooltip = '未检测到 Syslab Julia 运行时，点击查看环境信息';
        statusBarItem.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
    } else {
        statusBarItem.text = `$(beaker) Syslab ${env.info.juliaVersion || ''}`.trim();
        statusBarItem.tooltip = [
            `Syslab: ${env.info.syslabHome}`,
            `Julia : ${env.juliaExe}`,
            `Depot : ${env.depot}`,
            '点击查看环境信息'
        ].join('\n');
        statusBarItem.backgroundColor = undefined;
    }
    statusBarItem.show();
}

/* -------------------------------------------------------------------------- */
/* 启动状态记录（~/.syslab-vscode/bridge-status.json，便于排查“扩展没生效”）    */
/* -------------------------------------------------------------------------- */

const SYSLAB_EXTENSION_IDS = [
    'TongYuan.syslab-julia',
    'TongYuan.julia-analyzer',
    'TongYuan.tymlang-ide',
    'TongYuan.app-designer'
];

function statusFilePath() {
    return path.join(path.dirname(envFilePath()), 'bridge-status.json');
}

/** 按扩展 ID 查找（VS Code 的 getExtension 区分大小写，这里统一小写比较） */
function findExtensionById(id) {
    const target = String(id).toLowerCase();
    for (const extension of vscode.extensions.all) {
        if (extension.id && extension.id.toLowerCase() === target) { return extension; }
    }
    return undefined;
}

function writeBridgeStatus(context, extra) {
    const env = resolveSyslab(false);
    const status = {
        updatedAt: new Date().toISOString(),
        vscodeVersion: vscode.version,
        envFile: envFilePath(),
        envFileExists: fs.existsSync(envFilePath()),
        envSource: (env && env.info) ? env.info.source : null,
        syslabHome: (env && env.info) ? env.info.syslabHome : null,
        juliaExe: env ? env.juliaExe : null,
        juliaAvailable: !!(env && env.available),
        syslabExtensions: {}
    };
    for (const id of SYSLAB_EXTENSION_IDS) {
        const extension = findExtensionById(id);
        status.syslabExtensions[id] = extension
            ? { installed: true, active: !!extension.isActive, id: extension.id }
            : { installed: false, active: false };
    }
    if (extra) { Object.assign(status, extra); }
    try {
        const file = statusFilePath();
        const dir = path.dirname(file);
        if (!fs.existsSync(dir)) { fs.mkdirSync(dir, { recursive: true }); }
        fs.writeFileSync(file, JSON.stringify(status, null, 2), 'utf8');
    } catch (err) { /* 忽略 */ }
    return status;
}

async function activate(context) {
    const env = resolveSyslab(false);

    // Syslab 外壳命令的空实现：必须尽早注册，否则 Syslab 扩展会在 activate 阶段失败
    let stubCount = 0;
    try {
        stubCount = await registerShellCommandStubs(context);
    } catch (err) {
        console.error('[syslab-bridge] 注册 Syslab 外壳命令占位失败：' + err.message);
    }

    // 记录启动状态，便于事后确认 Syslab 扩展是否真的激活成功
    const statusTimers = [];
    writeBridgeStatus(context, { shellStubs: stubCount });
    for (const delay of [8000, 20000, 45000]) {
        statusTimers.push(setTimeout(() => writeBridgeStatus(context, { shellStubs: stubCount }), delay));
    }

    // Syslab 的“代码节”视图（code-section.view）由 when 条件控制，
    // 提前置为 true，保证 Syslab Julia 扩展激活时该视图已注册。
    try {
        await vscode.commands.executeCommand('setContext', 'shouldShowCodeSectionView', true);
    } catch (err) { /* 忽略 */ }

    console.log('[syslab-bridge] activated. syslab=' +
        (env && env.info ? env.info.syslabHome : '(未探测到)') +
        ' julia=' + (env ? env.juliaExe : '-') +
        ' envFile=' + envFilePath() +
        ' shellStubs=' + stubCount);

    context.subscriptions.push(
        vscode.commands.registerCommand('syslab.runFile', runFile),
        vscode.commands.registerCommand('syslab.runFileInREPL', runFileInREPL),
        vscode.commands.registerCommand('syslab.runSelection', runSelection),
        vscode.commands.registerCommand('syslab.startREPL', startREPL),
        vscode.commands.registerCommand('syslab.stopREPL', stopREPL),
        vscode.commands.registerCommand('syslab.openInSyslab', openInSyslab),
        vscode.commands.registerCommand('syslab.showEnvironment', showEnvironment),
        vscode.commands.registerCommand('syslab.checkHealth', checkHealth),
        vscode.commands.registerCommand('syslab.openDepot', () => {
            const env = resolveSyslab(false);
            openFolder(env ? env.depot : '');
        }),
        vscode.commands.registerCommand('syslab.openInstallDir', () => {
            const env = resolveSyslab(false);
            openFolder(env && env.info ? env.info.syslabHome : '');
        }),
        vscode.extensions.onDidChange(() => writeBridgeStatus(context, { shellStubs: stubCount })),
        vscode.window.onDidChangeActiveTextEditor(() => writeBridgeStatus(context, { shellStubs: stubCount }))
    );

    // “Syslab Julia” 终端配置文件：任何终端里都能直接进入 Syslab 环境
    context.subscriptions.push(
        vscode.window.registerTerminalProfileProvider('syslab.juliaTerminal', {
            provideTerminalProfile() {
                const env = resolveSyslab(false);
                if (!env || !env.available) {
                    vscode.window.showErrorMessage('未检测到 MWORKS Syslab Julia 运行时。');
                    return undefined;
                }
                const args = [`--project=${projectPath(env)}`, '-i', '--banner=no'];
                const pkgs = preloadPackages();
                if (pkgs.length) {
                    args.push('-e', `using ${pkgs.join(', ')}`);
                }
                return new vscode.TerminalProfile({
                    name: 'Syslab Julia',
                    shellPath: env.juliaExe,
                    shellArgs: args,
                    cwd: workspaceCwd(),
                    env: terminalEnv(env),
                    iconPath: new vscode.ThemeIcon('beaker')
                });
            }
        })
    );

    context.subscriptions.push(
        vscode.workspace.onDidChangeConfiguration(e => {
            if (e.affectsConfiguration('syslab')) {
                cachedEnv = null;
                updateStatusBar();
            }
        })
    );

    context.subscriptions.push({
        dispose() {
            for (const timer of statusTimers) { clearTimeout(timer); }
            if (statusBarItem) { statusBarItem.dispose(); }
            if (outputChannel) { outputChannel.dispose(); }
            if (replTerminal) { replTerminal.dispose(); }
        }
    });

    updateStatusBar();
}

function deactivate() { }

module.exports = { activate, deactivate };
