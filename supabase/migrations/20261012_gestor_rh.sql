-- ═══════════════════════════════════════════════════════════════════════
--  Scholaris — perfil «Gestor de RH» (fase 1 do módulo de RH)
--  2026-10-12 · app v6.251 (iQRA) / v6.270 (Atlântico). Serve para as duas
--  escolas. Idempotente.
--
--  O Gestor de RH gere o pessoal: fichas e contratos, dados confidenciais
--  (salário, NUIT, IBAN do funcionário), faltas e férias do pessoal e
--  avaliações de desempenho. NÃO lê alunos, encarregados, propinas,
--  pagamentos, facturas nem as finanças da escola (fica fora de sou_staff()
--  e de sou_admin()). Não cria contas: isso continua a ser da direcção.
--  A folha de salários entra na fase 2 (tabela própria).
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1) Novo papel ────────────────────────────────────────────────────────
alter type public.perfil_utilizador add value if not exists 'gestor-rh';

-- compara como texto: o valor novo do enum só pode ser usado depois do commit
create or replace function public.sou_rh()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $f$
  select exists(select 1 from public.perfis
                 where id = auth.uid() and perfil::text = 'gestor-rh')
$f$;

-- ── 2) Fichas do pessoal ─────────────────────────────────────────────────
drop policy if exists staff_rh_select on public.staff;
create policy staff_rh_select on public.staff
  for select to authenticated using (escola_id = minha_escola() and sou_rh());
drop policy if exists staff_rh_insert on public.staff;
create policy staff_rh_insert on public.staff
  for insert to authenticated with check (escola_id = minha_escola() and sou_rh());
drop policy if exists staff_rh_update on public.staff;
create policy staff_rh_update on public.staff
  for update to authenticated
  using (escola_id = minha_escola() and sou_rh())
  with check (escola_id = minha_escola() and sou_rh());

-- (de passagem) a direcção só altera/apaga pessoal da própria escola
drop policy if exists staff_update on public.staff;
create policy staff_update on public.staff
  for update to authenticated
  using (escola_id = minha_escola() and sou_gestor_dir())
  with check (escola_id = minha_escola() and sou_gestor_dir());
drop policy if exists staff_delete on public.staff;
create policy staff_delete on public.staff
  for delete to authenticated using (escola_id = minha_escola() and sou_gestor_dir());

-- ── 3) Dados confidenciais (salário, NUIT, IBAN do funcionário) ──────────
drop policy if exists staffconf_rh on public.staff_confidencial;
create policy staffconf_rh on public.staff_confidencial
  for all to authenticated
  using (escola_id = minha_escola() and sou_rh())
  with check (escola_id = minha_escola() and sou_rh());

-- ── 4) Férias ────────────────────────────────────────────────────────────
drop policy if exists ferias_rh on public.staff_ferias;
create policy ferias_rh on public.staff_ferias
  for all to authenticated
  using (escola_id = minha_escola() and sou_rh())
  with check (escola_id = minha_escola() and sou_rh());

-- ── 5) Faltas do PESSOAL (as dos alunos ficam fora) ──────────────────────
drop policy if exists faltas_rh on public.faltas;
create policy faltas_rh on public.faltas
  for all to authenticated
  using (escola_id = minha_escola() and sou_rh() and staff_id is not null)
  with check (escola_id = minha_escola() and sou_rh() and staff_id is not null);

-- ── 6) Avaliações de desempenho (sem apagar) ─────────────────────────────
drop policy if exists avalstaff_rh_select on public.avaliacoes_staff;
create policy avalstaff_rh_select on public.avaliacoes_staff
  for select to authenticated using (escola_id = minha_escola() and sou_rh());
drop policy if exists avalstaff_rh_insert on public.avaliacoes_staff;
create policy avalstaff_rh_insert on public.avaliacoes_staff
  for insert to authenticated with check (escola_id = minha_escola() and sou_rh());
drop policy if exists avalstaff_rh_update on public.avaliacoes_staff;
create policy avalstaff_rh_update on public.avaliacoes_staff
  for update to authenticated
  using (escola_id = minha_escola() and sou_rh())
  with check (escola_id = minha_escola() and sou_rh());

-- ── 7) Ver que funcionários têm conta (só perfis de pessoal) ─────────────
drop policy if exists perfis_rh_select on public.perfis;
create policy perfis_rh_select on public.perfis
  for select to authenticated
  using (escola_id = minha_escola() and sou_rh() and staff_id is not null);

-- ── 8) O registo de auditoria do browser também aceita o RH ──────────────
drop policy if exists auditoria_insert on public.auditoria;
create policy auditoria_insert on public.auditoria
  for insert to authenticated
  with check (escola_id = minha_escola() and (sou_staff() or sou_rh()));

-- ── 9) Facturas: tal como o professor, o RH não lê ───────────────────────
drop policy if exists professor_sem_facturas on public.facturas;
create policy professor_sem_facturas on public.facturas
  as restrictive for select to authenticated
  using (coalesce(meu_perfil(), '') not in ('professor', 'gestor-rh'));
