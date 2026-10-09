-- ═══════════════════════════════════════════════════════════════════════
--  Scholaris (Colégio iQRA) — segurança: candidaturas e escrita indevida
--  2026-10-09 · app v6.245 · correr no SQL Editor do Supabase, de uma vez.
--  Idempotente: pode correr-se duas vezes.
--
--  Encontrado na auditoria de 2026-10-08, reconfirmado a 2026-10-09:
--   A) candidaturas aceitavam gravação de QUALQUER pessoa sem conta, para
--      qualquer escola (cand_public_insert / cand_insert_publico, with check
--      true). Junto com o ecrã Admissões, que não tratava o texto, dava para
--      correr código na sessão de quem o abrisse. O ecrã foi corrigido na
--      v6.245; aqui fecha-se a porta. O formulário público não está ligado.
--   B) cand_staff_all dava a QUALQUER conta da escola (aluno, encarregado,
--      professor) acesso total às candidaturas: ler nomes e telefones,
--      alterar e apagar.
--   C) horarios, graduacoes, planos_tematicos e categorias_pagamento tinham
--      uma única política ALL só por escola: qualquer conta da escola podia
--      criar, alterar e apagar.
--
--  Depois disto (sou_admin = gestor, director, dir. pedagógico, dir. de ciclo,
--  secretário; sou_staff = sou_admin + professor):
--   candidaturas          ler/criar/alterar: sou_admin · apagar: gestor/director
--   horarios              ler: toda a escola · escrever: sou_admin
--   graduacoes            ler: pessoal (sou_staff) · escrever: sou_admin
--   planos_tematicos      ler: toda a escola · criar/alterar: sou_staff
--                         (o professor marca o tema como dado) · apagar: sou_admin
--   categorias_pagamento  ler: toda a escola · escrever: gestor/director
-- ═══════════════════════════════════════════════════════════════════════

-- ── A + B) Candidaturas ──────────────────────────────────────────────────
drop policy if exists cand_public_insert  on public.candidaturas;
drop policy if exists cand_insert_publico on public.candidaturas;
drop policy if exists cand_staff_all      on public.candidaturas;

drop policy if exists cand_select on public.candidaturas;
create policy cand_select on public.candidaturas
  for select to authenticated
  using (escola_id = minha_escola() and sou_admin());

drop policy if exists cand_insert on public.candidaturas;
create policy cand_insert on public.candidaturas
  for insert to authenticated
  with check (escola_id = minha_escola() and sou_admin());

drop policy if exists cand_update on public.candidaturas;
create policy cand_update on public.candidaturas
  for update to authenticated
  using (escola_id = minha_escola() and sou_admin())
  with check (escola_id = minha_escola() and sou_admin());

drop policy if exists cand_delete on public.candidaturas;
create policy cand_delete on public.candidaturas
  for delete to authenticated
  using (escola_id = minha_escola() and sou_gestor_dir());

-- ── C) Horários ──────────────────────────────────────────────────────────
drop policy if exists horarios_tenant on public.horarios;
drop policy if exists horarios_select on public.horarios;
create policy horarios_select on public.horarios
  for select to authenticated using (escola_id = minha_escola());
drop policy if exists horarios_write on public.horarios;
create policy horarios_write on public.horarios
  for all to authenticated
  using (escola_id = minha_escola() and sou_admin())
  with check (escola_id = minha_escola() and sou_admin());

-- ── C) Graduações ────────────────────────────────────────────────────────
drop policy if exists graduacoes_tenant on public.graduacoes;
drop policy if exists graduacoes_select on public.graduacoes;
create policy graduacoes_select on public.graduacoes
  for select to authenticated using (escola_id = minha_escola() and sou_staff());
drop policy if exists graduacoes_write on public.graduacoes;
create policy graduacoes_write on public.graduacoes
  for all to authenticated
  using (escola_id = minha_escola() and sou_admin())
  with check (escola_id = minha_escola() and sou_admin());

-- ── C) Planos temáticos ──────────────────────────────────────────────────
drop policy if exists planos_tematicos_tenant on public.planos_tematicos;
drop policy if exists planos_tematicos_select on public.planos_tematicos;
create policy planos_tematicos_select on public.planos_tematicos
  for select to authenticated using (escola_id = minha_escola());
drop policy if exists planos_tematicos_insert on public.planos_tematicos;
create policy planos_tematicos_insert on public.planos_tematicos
  for insert to authenticated with check (escola_id = minha_escola() and sou_staff());
drop policy if exists planos_tematicos_update on public.planos_tematicos;
create policy planos_tematicos_update on public.planos_tematicos
  for update to authenticated
  using (escola_id = minha_escola() and sou_staff())
  with check (escola_id = minha_escola() and sou_staff());
drop policy if exists planos_tematicos_delete on public.planos_tematicos;
create policy planos_tematicos_delete on public.planos_tematicos
  for delete to authenticated using (escola_id = minha_escola() and sou_admin());

-- ── C) Categorias de pagamento (escola_id é TEXT nesta tabela) ───────────
drop policy if exists cat_pag_tenant on public.categorias_pagamento;
drop policy if exists cat_pag_select on public.categorias_pagamento;
create policy cat_pag_select on public.categorias_pagamento
  for select to authenticated using (escola_id = (minha_escola())::text);
drop policy if exists cat_pag_write on public.categorias_pagamento;
create policy cat_pag_write on public.categorias_pagamento
  for all to authenticated
  using (escola_id = (minha_escola())::text and sou_gestor_dir())
  with check (escola_id = (minha_escola())::text and sou_gestor_dir());

-- ── Verificação (deve listar só as políticas novas destas 5 tabelas) ─────
-- select tablename, policyname, cmd, roles::text from pg_policies
--  where tablename in ('candidaturas','horarios','graduacoes','planos_tematicos','categorias_pagamento')
--  order by 1,2;
