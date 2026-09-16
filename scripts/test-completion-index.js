/*---------------------------------------------------------------------------------------------
 *  补全索引自检：用真实的 completion.json 验证「上下文解析 + 索引检索」是否正常
 *
 *  用法（由 scripts\Test-CompletionIndex.ps1 调用，也可直接用 node 跑）：
 *    node test-completion-index.js [索引路径]
 *
 *  退出码：0 = 全部通过，1 = 有失败项（缺索引/断言不成立）
 *--------------------------------------------------------------------------------------------*/
'use strict';

const path = require('path');
const os = require('os');
const fs = require('fs');

const lib = require(path.join(__dirname, '..', 'extension', 'lib', 'completion.js'));

const indexPath = process.argv[2] || path.join(os.homedir(), '.syslab-vscode', 'completion.json');

const lines = [];
let failures = 0;

function log(text) {
    lines.push(text);
}

function check(desc, ok, detail) {
    if (!ok) { failures++; }
    log(`  [${ok ? '通过' : '失败'}] ${desc}${detail ? '  ' + detail : ''}`);
}

log(`索引文件 : ${indexPath}`);
if (!fs.existsSync(indexPath)) {
    log('  [失败] 索引不存在 —— 先运行 scripts\\Build-CompletionIndex.ps1');
    console.log(lines.join('\n'));
    process.exitCode = 1;
    return;
}

const index = lib.loadIndex(indexPath);
if (!index) {
    log('  [失败] 索引无法解析（JSON 结构里没有 items 数组）');
    console.log(lines.join('\n'));
    process.exitCode = 1;
    return;
}

const packages = index.packages || [];
log(`索引内容 : ${index.items.length} 项 / ${packages.length} 个包 ${packages.join(',')}`);
log(`生成信息 : julia ${index.julia || '?'} | ${index.generatedAt || '?'}`);

check('索引条目数 > 100', index.items.length > 100, `实际 ${index.items.length}`);
check('索引里记录了包列表', packages.length > 0, packages.join(','));

// --- 上下文解析 -------------------------------------------------------------
const ctxCases = [
    { desc: '空行无前缀', line: '    ', ch: 4, prefix: '', memberOf: null, inUsing: false },
    { desc: '标识符前缀 pl', line: '    pl', ch: 6, prefix: 'pl', memberOf: null, inUsing: false },
    { desc: '成员访问 TyPlot.fi', line: 'TyPlot.fi', ch: 9, prefix: 'fi', memberOf: 'TyPlot', inUsing: false },
    { desc: '赋值右侧 TyPlot.su', line: 'x = TyPlot.su', ch: 13, prefix: 'su', memberOf: 'TyPlot', inUsing: false },
    { desc: 'using 之后的包名', line: 'using TyA', ch: 9, prefix: 'TyA', memberOf: null, inUsing: true }
];
for (const c of ctxCases) {
    const ctx = lib.detectContext(c.line, c.ch);
    check(`解析「${c.desc}」`, ctx.prefix === c.prefix && ctx.memberOf === c.memberOf && ctx.inUsing === c.inUsing,
        `prefix="${ctx.prefix}" memberOf=${ctx.memberOf} inUsing=${ctx.inUsing}`);
}

// --- 前缀补全 ---------------------------------------------------------------
const prefixHits = lib.searchSymbols(index, { prefix: 'pl', limit: 50 });
check('前缀 pl 有候选', prefixHits.length > 0, `${prefixHits.length} 项`);
check('前缀 pl 的候选都以 pl 开头', prefixHits.every(item => item.n.startsWith('pl')),
    prefixHits.slice(0, 6).map(item => item.n).join(', '));

// --- 成员补全（按包过滤）----------------------------------------------------
function memberCase(pkg, prefix, limit) {
    const hits = lib.searchSymbols(index, { prefix: prefix, memberOf: pkg, limit: limit || 50 });
    const summary = hits.slice(0, 8).map(item => item.n).join(', ');
    check(`成员补全 ${pkg}.${prefix} 有候选`, hits.length > 0, `${hits.length} 项: ${summary}`);
    check(`成员补全 ${pkg}.${prefix} 只含 ${pkg}`,
        hits.every(item => item.p === pkg), [...new Set(hits.map(item => item.p))].join(','));
    check(`成员补全 ${pkg}.${prefix} 都以前缀开头`,
        hits.every(item => item.n.startsWith(prefix)), summary);
    return hits;
}

if (packages.includes('TyPlot')) {
    const hits = memberCase('TyPlot', 'fi');
    check('TyPlot.fi 命中 figure', hits.some(item => item.n === 'figure'),
        hits.map(item => item.n).join(', '));
}
if (packages.includes('TyMath')) {
    memberCase('TyMath', 'fi');
}

// --- using 之后的包名补全 ---------------------------------------------------
const candidates = [...packages, 'TyAppDesigner', 'TyStatistics', 'DataFrames', 'LinearAlgebra'];
const usingHits = lib.searchPackages(candidates, 'TyA', 20);
check('using TyA 命中 TyAppDesigner', usingHits.includes('TyAppDesigner'), usingHits.join(', '));
check('using TyA 结果都是 TyA 开头', usingHits.every(name => name.startsWith('TyA')), usingHits.join(', '));

// --- 文档（可能用 -NoDocs 生成，因此只报告不判定）----------------------------
const withDoc = index.items.find(item => item.d && item.d.length > 0);
log(`文档抽样 : ${withDoc ? `[${withDoc.p}] ${withDoc.n} —— ${withDoc.d.slice(0, 70)}` : '（索引未包含文档，生成时加了 -NoDocs）'}`);

log(failures === 0
    ? '全部检查通过：离线补全索引可用 ✓'
    : `有 ${failures} 项检查失败 ✗`);

const report = lines.join('\n');
console.log(report);
try {
    fs.writeFileSync(path.join(os.tmpdir(), 'completion-index-test.txt'), report, 'utf8');
} catch (err) { /* 忽略：写不了临时文件不影响结论 */ }

process.exitCode = failures === 0 ? 0 : 1;
