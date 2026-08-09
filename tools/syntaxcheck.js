// Syntax-checks every inline <script> block in a single-file HTML app.
// Parses without executing, so it catches unbalanced template literals,
// stray backticks and broken nesting - the failure mode most likely when
// hand-editing 40k lines of interpolated HTML.
const fs = require('fs');
const vm = require('vm');

const file = process.argv[2];
const src = fs.readFileSync(file, 'utf8');

// Track line numbers so a failure points at the real place in the file.
const lineOf = (idx) => src.slice(0, idx).split('\n').length;

const re = /<script\b([^>]*)>([\s\S]*?)<\/script>/gi;
let m, checked = 0, skipped = 0;
const failures = [];

while ((m = re.exec(src)) !== null) {
  const attrs = m[1] || '';
  const code = m[2];
  if (/\bsrc\s*=/i.test(attrs)) { skipped++; continue; }
  if (!code.trim()) { skipped++; continue; }

  const startLine = lineOf(m.index);
  try {
    // new vm.Script parses without running.
    new vm.Script(code, { filename: `${file}:<script@${startLine}>` });
    checked++;
  } catch (e) {
    failures.push({ startLine, message: e.message });
  }
}

console.log(`inline <script> blocks parsed OK : ${checked}`);
console.log(`skipped (src= or empty)          : ${skipped}`);
console.log(`FAILURES                         : ${failures.length}`);
for (const f of failures) {
  console.log(`\n  x <script> starting at line ${f.startLine}`);
  console.log(`    ${f.message}`);
}
process.exit(failures.length ? 1 : 0);
