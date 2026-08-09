// 1) Self-test the syntax checker (it must FAIL on broken code).
// 2) Extract __escH / __escA from index.html and test them against payloads.
const fs = require('fs');
const vm = require('vm');

let pass = 0, fail = 0;
const ok = (name, cond, got) => {
  if (cond) { pass++; console.log(`  PASS  ${name}`); }
  else { fail++; console.log(`  FAIL  ${name}\n        got: ${JSON.stringify(got)}`); }
};

// ---- 1. checker self-test -------------------------------------------------
console.log('\nSyntax-checker self-test');
let caught = false;
try { new vm.Script('const x = `unterminated'); } catch (e) { caught = true; }
ok('vm.Script rejects an unterminated template literal', caught, caught);

// ---- 2. load the real helpers out of index.html ---------------------------
const src = fs.readFileSync(process.argv[2], 'utf8');
const block = src.match(/window\.__escH[\s\S]*?^};/m);
const block2 = src.match(/window\.__escA[\s\S]*?^};/m);
if (!block || !block2) { console.log('\nCould not locate helpers in index.html'); process.exit(1); }

const sandbox = { window: {} };
vm.createContext(sandbox);
vm.runInContext(block[0] + '\n' + block2[0], sandbox);
const H = sandbox.window.__escH, A = sandbox.window.__escA;

console.log('\n__escH — HTML text context');
ok('neutralises <img onerror>',
   !/<img/.test(H('<img src=x onerror="alert(1)">')),
   H('<img src=x onerror="alert(1)">'));
ok('escapes < > & " \'',
   H(`<>&"'`) === '&lt;&gt;&amp;&quot;&#39;',
   H(`<>&"'`));
ok('null becomes empty string', H(null) === '', H(null));
ok('undefined becomes empty string', H(undefined) === '', H(undefined));
ok('leaves ordinary Portuguese text intact',
   H('Faltou à aula de Matemática') === 'Faltou à aula de Matemática',
   H('Faltou à aula de Matemática'));
ok('ampersand escaped once, not double-escaped',
   H('Pais & Encarregados') === 'Pais &amp; Encarregados',
   H('Pais & Encarregados'));

console.log('\n__escA — inside onclick="fn(\'...\')"');
ok('breaks out of neither the JS string nor the attribute',
   !/[^\\]'/.test(A("'); alert(1); ('")) && !/"/.test(A('" onmouseover="alert(1)')),
   A("'); alert(1); ('"));
ok('escapes a lone backslash',
   A('a\\b') === 'a\\\\b',
   A('a\\b'));
ok('backslash-quote cannot re-open the string',
   A("\\'") === "\\\\\\'",
   A("\\'"));
ok('a normal uuid passes through unchanged',
   A('7c9e6679-7425-40de-944b-e07fc1f90ae7') === '7c9e6679-7425-40de-944b-e07fc1f90ae7',
   A('7c9e6679-7425-40de-944b-e07fc1f90ae7'));

// ---- 3. end-to-end: build the attribute and confirm it parses safely ------
console.log('\nEnd-to-end attribute construction');
const evil = "'); document.title='pwned'; ('";
const attr = `onclick="abrirDesfecho('${A(evil)}')"`;
ok('payload stays inside the JS string literal',
   attr.split("'").length === 4 + (A(evil).match(/\\'/g) || []).length * 2 || !/[^\\\\]';/.test(attr),
   attr);
let parsedSafely = true;
try { new vm.Script(`abrirDesfecho('${A(evil)}')`); } catch (e) { parsedSafely = false; }
ok('generated JS still parses as a single call', parsedSafely, parsedSafely);

console.log(`\n${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
