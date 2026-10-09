-- ═══════════════════════════════════════════════════════════════════════
--  Scholaris — o professor deixa de alterar alunos, matrículas, facturas,
--  turmas e disciplinas
--  2026-10-09 · app v6.247 · correr no SQL Editor do Supabase, de uma vez.
--  Idempotente: pode correr-se duas vezes.
--
--  Encontrado na análise OWASP de 2026-10-09 (A01 — controlo de acessos),
--  provado no iQRA com uma sessão de professor simulada e desfeita no fim:
--   · alunos_update e mat_update usavam só sou_staff() — qualquer professor
--     alterava bolsa %, isenções, encarregado e estado de todos os alunos e
--     matrículas (e sem verificar a escola);
--   · facturas_alterar só verificava a escola — o professor mudava valores
--     e o estado (ex.: «liquidada») das facturas;
--   · turmas_tenant e disciplinas_tenant (ALL, só por escola) deixavam o
--     professor alterar propinas das turmas, criar e apagar turmas/disciplinas.
--
--  No ecrã, estas gravações só existem para a direcção e a secretaria
--  (matrícula, alocação, bolsas, propinas, facturas, configuração). O
--  professor continua a gravar faltas, aulas dadas, notas, ocorrências,
--  comunicados/recados, planos (marcar como dado) e correcção de trabalhos.
--
--  Depois disto (sou_admin = gestor, director, dir. pedagógico, dir. de ciclo,
--  secretário):
--   alunos       alterar: sou_admin da própria escola (criar já era sou_admin;
--                apagar continua só o director)
--   matriculas   alterar: sou_admin da própria escola
--   facturas     alterar: sou_admin da própria escola
--   turmas       ler: toda a escola · escrever: sou_admin
--   disciplinas  ler: toda a escola · escrever: sou_admin
--  As políticas restritivas familia_* continuam como estão.
-- ═══════════════════════════════════════════════════════════════════════

-- ── Alunos ───────────────────────────────────────────────────────────────
drop policy if exists alunos_update on public.alunos;
create policy alunos_update on public.alunos
  for update to authenticated
  using (escola_id = minha_escola() and sou_admin())
  with check (escola_id = minha_escola() and sou_admin());

-- ── Matrículas ───────────────────────────────────────────────────────────
drop policy if exists mat_update on public.matriculas;
create policy mat_update on public.matriculas
  for update to authenticated
  using (escola_id = minha_escola() and sou_admin())
  with check (escola_id = minha_escola() and sou_admin());

-- ── Facturas ─────────────────────────────────────────────────────────────
drop policy if exists facturas_alterar on public.facturas;
create policy facturas_alterar on public.facturas
  for update to authenticated
  using (escola_id = minha_escola() and sou_admin())
  with check (escola_id = minha_escola() and sou_admin());

-- ── Turmas (a leitura já existe: turmas_ler_escola) ──────────────────────
drop policy if exists turmas_tenant on public.turmas;
drop policy if exists turmas_write  on public.turmas;
create policy turmas_write on public.turmas
  for all to authenticated
  using (escola_id = minha_escola() and sou_admin())
  with check (escola_id = minha_escola() and sou_admin());

-- ── Disciplinas ──────────────────────────────────────────────────────────
drop policy if exists disciplinas_tenant on public.disciplinas;
drop policy if exists disciplinas_select on public.disciplinas;
create policy disciplinas_select on public.disciplinas
  for select to authenticated using (escola_id = minha_escola());
drop policy if exists disciplinas_write on public.disciplinas;
create policy disciplinas_write on public.disciplinas
  for all to authenticated
  using (escola_id = minha_escola() and sou_admin())
  with check (escola_id = minha_escola() and sou_admin());

-- ── Verificação (opcional) ───────────────────────────────────────────────
-- select tablename, policyname, cmd, coalesce(with_check, qual) from pg_policies
--  where tablename in ('alunos','matriculas','facturas','turmas','disciplinas')
--    and policyname not like 'familia_%' order by 1, 3, 2;
