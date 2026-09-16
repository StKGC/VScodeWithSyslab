/*---------------------------------------------------------------------------------------------
 *  Julia / M 代码补全的纯逻辑部分（不依赖 vscode，便于单测）
 *
 *  数据源：由 scripts\Build-CompletionIndex.ps1 生成的 completion.json
 *          （Syslab 自带 Julia 把包的导出符号 + 一行文档导出成 JSON）
 *--------------------------------------------------------------------------------------------*/
'use strict';

const fs = require('fs');

const IDENT_TAIL = /[A-Za-z_][A-Za-z0-9_!]*$/;
const MEMBER_TAIL = /([A-Za-z_][A-Za-z0-9_]*)\.[A-Za-z0-9_!]*$/;
const USING_TAIL = /(?:^|[;\s(])(?:using|import)\s+[A-Za-z0-9_,\s.:]*$/;

/**
 * 解析光标前的上下文。
 * @param {string} lineText 当前行的完整文本
 * @param {number} character 光标列（0 基）
 * @returns {{prefix:string, memberOf:(string|null), inUsing:boolean}}
 */
function detectContext(lineText, character) {
    const before = String(lineText || '').slice(0, Math.max(0, character));
    const identMatch = IDENT_TAIL.exec(before);
    const prefix = identMatch ? identMatch[0] : '';
    const memberMatch = MEMBER_TAIL.exec(before);
    const memberOf = memberMatch ? memberMatch[1] : null;
    const inUsing = !memberOf && USING_TAIL.test(before);
    return { prefix, memberOf, inUsing };
}

/** 从索引里按前缀/包名过滤（先精确前缀，再退化为忽略大小写前缀） */
function searchSymbols(index, options) {
    const items = (index && index.items) || [];
    const prefix = (options && options.prefix) || '';
    const memberOf = (options && options.memberOf) || null;
    const limit = (options && options.limit) || 200;
    const excludePackages = new Set((options && options.excludePackages) || []);

    const pool = [];
    for (const item of items) {
        if (!item || !item.n) { continue; }
        if (memberOf && item.p !== memberOf) { continue; }
        if (!memberOf && item.p && excludePackages.has(item.p)) { continue; }
        pool.push(item);
    }

    const pick = (matcher) => {
        const out = [];
        for (const item of pool) {
            if (!matcher(item.n)) { continue; }
            out.push(item);
            if (out.length >= limit) { break; }
        }
        return out;
    };

    let hits = pick(name => name.startsWith(prefix));
    if (hits.length === 0 && prefix) {
        const lower = prefix.toLowerCase();
        hits = pick(name => name.toLowerCase().startsWith(lower));
    }
    // 包名不同但同名的符号只保留一个（优先按出现顺序，即包列表顺序）
    const seen = new Set();
    return hits.filter(item => {
        const key = item.n;
        if (seen.has(key)) { return false; }
        seen.add(key);
        return true;
    });
}

/** `using` / `import` 之后的包名补全 */
function searchPackages(packageNames, prefix, limit) {
    const max = limit || 200;
    const names = Array.from(new Set(packageNames || []));
    const pick = (matcher) => {
        const out = [];
        for (const name of names) {
            if (!matcher(name)) { continue; }
            out.push(name);
            if (out.length >= max) { break; }
        }
        return out;
    };
    let hits = pick(name => name.startsWith(prefix || ''));
    if (hits.length === 0 && prefix) {
        const lower = prefix.toLowerCase();
        hits = pick(name => name.toLowerCase().startsWith(lower));
    }
    return hits;
}

/** 读取索引文件（失败返回 null） */
function loadIndex(filePath) {
    try {
        if (!filePath || !fs.existsSync(filePath)) { return null; }
        const raw = fs.readFileSync(filePath, 'utf8').replace(/^\uFEFF/, '');
        const data = JSON.parse(raw);
        if (!data || !Array.isArray(data.items)) { return null; }
        return data;
    } catch (err) {
        return null;
    }
}

/** 把索引里的种类映射成 VS Code 的 CompletionItemKind 名字（由调用方映射成枚举） */
const KIND_PRIORITY = {
    function: 0,
    type: 1,
    module: 2,
    const: 3,
    value: 4
};

module.exports = {
    detectContext,
    searchSymbols,
    searchPackages,
    loadIndex,
    KIND_PRIORITY
};
