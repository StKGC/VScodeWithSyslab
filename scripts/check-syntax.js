const fs = require('fs');
const vm = require('vm');
const path = require('path');
const os = require('os');
const lines = [];
for (const f of process.argv.slice(2)) {
    if (f.endsWith('.json')) {
        try {
            JSON.parse(fs.readFileSync(f, 'utf8').replace(/^\uFEFF/, ''));
            lines.push('JSON OK ' + f);
        } catch (e) {
            lines.push('JSON FAIL ' + f + ' :: ' + e.message);
            process.exitCode = 1;
        }
        continue;
    }
    try {
        new vm.Script(fs.readFileSync(f, 'utf8'), { filename: f });
        lines.push('OK   ' + f);
    } catch (e) {
        lines.push('FAIL ' + f + ' :: ' + e.message);
        process.exitCode = 1;
    }
}
const report = path.join(os.tmpdir(), 'syslab-syntax-check.txt');
fs.writeFileSync(report, lines.join(os.EOL), 'utf8');
console.error(lines.join(os.EOL));
console.error('report: ' + report);

