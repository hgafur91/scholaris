// Verification pass for a single-file, patch-stacked app.
//
// The core problem: `function foo(){}` at line 3000 tells you nothing, because
// line 35000 may do `window.foo = ...`. Reviewing by reading definitions gives
// wrong answers. This resolves, for any identifier, EVERY site that defines or
// reassigns it, in file order, so the last-wins result is explicit.
//
// Usage:
//   node verify.js <index.html>              -> run the full claim battery
//   node verify.js <index.html> name [name2] -> resolve specific identifiers

const fs = require('fs');
const path = require('path');

const file = process.argv[2];
const src = fs.readFileSync(file, 'utf8');
const lines = src.split('\n');
const names = process.argv.slice(3);

const lineOf = (idx) => src.slice(0, idx).split('\n').length;

// ---------------------------------------------------------------- overrides
function resolve(name) {
  const n = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const pats = [
    [new RegExp(`function\\s+${n}\\s*\\(`, 'g'), 'function decl'],
    [new RegExp(`window\\.${n}\\s*=`, 'g'), 'window assign'],
    [new RegExp(`(?:^|[^.\\w])${n}\\s*=\\s*function`, 'gm'), 'bare assign'],
    [new RegExp(`(?:const|let|var)\\s+${n}\\s*=`, 'g'), 'declaration'],
  ];
  const hits = [];
  for (const [re, kind] of pats) {
    let m;
    while ((m = re.exec(src)) !== null) hits.push({ line: lineOf(m.index), kind });
  }
  hits.sort((a, b) => a.line - b.line);
  const uniq = hits.filter((h, i) => i === 0 || h.line !== hits[i - 1].line);

  // A later assignment does NOT necessarily kill an earlier one. The codebase's
  // dominant idiom is `const _origX = foo; foo = function(){ ... _origX() ... }`
  // — a decorator chain where every earlier version still runs. Distinguish
  // that from a flat replacement, which really does make earlier ones dead.
  for (const h of uniq) {
    if (h.kind === 'function decl') { h.mode = 'defines'; continue; }

    // The reported line can be one early: the 'bare assign' pattern consumes a
    // leading char, and when that char is a newline the match index lands on the
    // previous line. So the capture window must include h.line itself.
    const before = lines.slice(Math.max(0, h.line - 4), h.line + 1).join('\n');
    const body = lines.slice(h.line - 1, h.line + 60).join('\n');

    // `window.X = X` just publishes the existing function to the global object.
    // It is not a redefinition and must not mark earlier code dead.
    if (new RegExp(`window\\.${n}\\s*=\\s*${n}\\s*[;,}]`).test(before + '\n' + body)) {
      h.mode = 'publishes'; continue;
    }

    const cap = before.match(
      new RegExp(`(?:const|let|var)\\s+(\\w+)\\s*=\\s*(?:window\\.)?${n}\\s*;`)
    );
    h.mode = cap && new RegExp(`\\b${cap[1]}\\b`).test(body) ? 'wraps' : 'replaces';
    if (h.mode === 'wraps') h.via = cap[1];
  }
  return uniq;
}

if (names.length) {
  for (const name of names) {
    const hits = resolve(name);
    console.log(`\n${name}`);
    if (!hits.length) { console.log('  (not found)'); continue; }

    // Walk backwards from the entry point: an earlier version is live only if
    // every reassignment above it delegates.
    let liveDown = true;
    const live = new Array(hits.length).fill(false);
    for (let i = hits.length - 1; i >= 0; i--) {
      live[i] = liveDown;
      // Only a flat replacement severs the chain. 'wraps' delegates onward and
      // 'publishes' is a no-op, so both leave earlier versions reachable.
      if (hits[i].mode === 'replaces' && i > 0) liveDown = false;
    }

    hits.forEach((h, i) => {
      const entry = i === hits.length - 1;
      const tag = entry ? 'ENTRY POINT' : (live[i] ? 'live (delegated to)' : 'DEAD CODE');
      const how = h.mode === 'wraps' ? `wraps via ${h.via}` : h.mode;
      console.log(
        `  ${entry ? '->' : '  '} line ${String(h.line).padEnd(6)} ${h.kind.padEnd(14)} ${how.padEnd(22)} ${tag}`
      );
    });
    if (hits.some((h, i) => i < hits.length - 1 && !live[i])) {
      console.log('     ^ editing a DEAD CODE line has no effect at runtime');
    }
  }
  process.exit(0);
}

// ------------------------------------------------------------------ battery
const count = (re) => (src.match(re) || []).length;
const rows = [];
const add = (claim, actual, verdict, note) => rows.push({ claim, actual, verdict, note: note || '' });

// referenced-but-missing assets
const dir = path.dirname(file);
for (const asset of ['manifest.webmanifest', 'sw.js', 'icon-192.png']) {
  const referenced = src.includes(asset);
  const exists = fs.existsSync(path.join(dir, asset));
  if (referenced) {
    add(`asset ${asset}`, exists ? 'present' : 'MISSING',
        exists ? 'ok' : 'CONFIRMED', exists ? '' : 'referenced but not in repo');
  }
}

// error handling
const emptyCatch = count(/catch\s*\([^)]*\)\s*\{\s*\}/g);
const allCatch = count(/catch\s*\(/g);
add('empty catch blocks', `${emptyCatch} of ${allCatch}`, emptyCatch > 100 ? 'CONFIRMED' : 'check');

// query hygiene
const selectAll = count(/\.select\(\s*['"]\*['"]\s*\)/g);
const limits = count(/\.limit\(/g);
add('select(*) vs limit()', `${selectAll} vs ${limits}`, 'CONFIRMED');
add('.maybeSingle()', String(count(/\.maybeSingle\(/g)), 'info');
const singleTotal = count(/\.single\(\)/g);
const singlePostWrite = (src.match(/\.(?:insert|update|upsert)\([\s\S]{0,400}?\.single\(\)/g) || []).length;
add('.single() total / post-write', `${singleTotal} / ~${singlePostWrite}`, 'info', 'post-write ones are safe');

// print launchers
const opens = (src.match(/window\.open\(/g) || []).length;
const guarded = (src.match(/window\.open\([\s\S]{0,300}?if\s*\(\s*!\s*\w+\s*\)/g) || []).length;
add('window.open() launchers', `${opens}, ~${guarded} guarded`, opens > 20 ? 'CONFIRMED' : 'check',
    'unguarded ones throw when popups are blocked');

// duplicated utilities
const moneyDefs = count(/function\s+(?:money|fmtN|nf|fmt)\s*\(/g);
add('local money/fmt helpers', String(moneyDefs), moneyDefs > 5 ? 'CONFIRMED' : 'check');

// rendering
add('innerHTML assignments', String(count(/\.innerHTML\s*=/g)), 'info');
add('innerHTML += (reparses)', String(count(/\.innerHTML\s*\+=/g)), 'info');

// concurrency
add('Promise.all uses', String(count(/Promise\.all\(/g)), 'info', 'boot is sequential if low');

// write idempotency
add('upsert / onConflict', `${count(/\.upsert\(/g)} / ${count(/onConflict/g)}`, 'info');

// tenancy
add("eq('escola_id') filters", String(count(/eq\(\s*['"]escola_id['"]/g)), 'info');

console.log(`\nVerification battery — ${path.basename(file)}\n`);
const w = [38, 20, 11];
console.log('CLAIM'.padEnd(w[0]) + 'ACTUAL'.padEnd(w[1]) + 'VERDICT'.padEnd(w[2]) + 'NOTE');
console.log('-'.repeat(100));
for (const r of rows) {
  console.log(
    r.claim.padEnd(w[0]) + String(r.actual).padEnd(w[1]) + r.verdict.padEnd(w[2]) + r.note
  );
}
console.log('');
