// docs/audits/performance/ahk/2026_09_27/profile.cjs

const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
if (!root) throw new Error('Pass the isolated checkout root');
const target = path.join(root, 'static/ergopti_plus/windows/tests/unit/test_tooltip_border_pool.ahk');
let source = fs.readFileSync(target, 'utf8');
const anchor = '\t\tP95 := _TBP_Percentile(Samples, 0.95)\n';
if (source.split(anchor).length !== 3 || source.includes('_TBP_RecordMeasurement')) {
    throw new Error('Expected two uninstrumented workloads');
}
let count = 0;
source = source.replaceAll(anchor, () => anchor + `\t\t_TBP_RecordMeasurement("${++count === 1 ? 'border' : 'preparation'}", Samples)\n`);
source += '\n_TBP_RecordMeasurement(Workload, Samples) {\n\tOutput := EnvGet("ERGOPTI_TBP_PROFILE")\n\tif Output == ""\n\t\tthrow Error("Missing measurement output")\n\tfor Index, Value in Samples\n\t\tFileAppend(Workload . "," . Index . "," . Value . "`n", Output, "UTF-8-RAW")\n}\n';
fs.writeFileSync(target, source);
