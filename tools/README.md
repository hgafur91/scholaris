# tools

Três scripts de verificação para o `index.html`. Só precisam de Node, não há
dependências para instalar.

## `verify.js` — quem é que ganha?

O problema central deste ficheiro: `function foo(){}` na linha 3000 não diz
nada, porque a linha 35000 pode fazer `window.foo = ...`. **Rever código a ler
definições dá respostas erradas.** Foi assim que quatro revisões automáticas
seguidas concluíram coisas falsas sobre este ficheiro.

Este script resolve, para qualquer nome, todos os sítios que o definem ou
reatribuem, por ordem, e diz qual deles corre de facto:

```bash
node tools/verify.js index.html rDash
```

```
rDash
     line 3749   function decl  defines                DEAD CODE
     line 11296  bare assign    wraps via _origRDash2  DEAD CODE
     line 12173  bare assign    wraps via _origRDash3  DEAD CODE
     line 17381  bare assign    replaces               live (delegated to)
     line 32555  window assign  wraps via _origRDash   live (delegated to)
  -> line 32557  window assign  wraps via _origRDash   ENTRY POINT
     ^ editing a DEAD CODE line has no effect at runtime
```

Distingue três casos, e a diferença é o que interessa:

| modo | significado |
|---|---|
| `wraps via _origX` | decorador: guarda a versão anterior e chama-a — as anteriores continuam vivas |
| `replaces` | substituição directa: tudo o que está acima fica **morto** |
| `publishes` | `window.X = X`, só expõe a função — não substitui nada |

**Corre isto antes de editar qualquer função.** Se a linha que ias mudar
aparece como `DEAD CODE`, a tua alteração não faz nada.

Sem argumentos, corre uma bateria de contagens sobre o ficheiro (catches
vazios, `select('*')` sem `limit()`, `window.open` sem guarda, ficheiros
referenciados que não existem, etc.):

```bash
node tools/verify.js index.html
```

## `syntaxcheck.js` — o ficheiro ainda parseia?

Faz parse (sem executar) de todos os blocos `<script>` inline. Apanha
template literals por fechar e crases perdidas — o erro mais provável quando
se edita HTML interpolado à mão.

```bash
node tools/syntaxcheck.js index.html
```

Corre **sempre** isto depois de editar o `index.html`. Sai com código 1 se
algum bloco não parsear.

## `esc.test.js` — os escapes aguentam?

Testa `window.__escH` e `window.__escA` contra payloads de XSS, nos dois
contextos onde são usados (texto em HTML e valor dentro de uma string JS num
atributo).

```bash
node tools/esc.test.js index.html
```
