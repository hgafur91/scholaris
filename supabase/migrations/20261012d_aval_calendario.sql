-- ═══════════════════════════════════════════════════════════════════════
--  Scholaris — calendário da avaliação de desempenho + alertas ao pessoal
--  2026-10-12 · app v6.255 (iQRA) / v6.274 (Atlântico). Idempotente.
--
--  O RH escolhe, para cada ano, quando decorre cada fase:
--    · revisão de meio do ano (chefias),
--    · auto-avaliação (cada funcionário),
--    · avaliação pelas chefias.
--  O servidor só aceita cada acção dentro das datas da fase (dia de Maputo).
--  Sem datas marcadas a fase está fechada. O RH e a direcção podem sempre
--  corrigir avaliações da chefia/revisão fora de prazo; a auto-avaliação é só
--  do próprio e só dentro do prazo.
--  aval_alertas() diz a cada pessoa o que tem por fazer — a app mostra o
--  alerta no perfil quando uma fase está a decorrer.
-- ═══════════════════════════════════════════════════════════════════════

create table if not exists public.aval_periodos (
  escola_id       uuid not null references public.escolas(id) on delete cascade,
  ano             int  not null,
  revisao_inicio  date, revisao_fim date,
  auto_inicio     date, auto_fim    date,
  chefia_inicio   date, chefia_fim  date,
  mensagem        text,
  actualizado_em  timestamptz not null default now(),
  actualizado_por text,
  primary key (escola_id, ano),
  check (revisao_fim is null or revisao_inicio is null or revisao_fim >= revisao_inicio),
  check (auto_fim    is null or auto_inicio    is null or auto_fim    >= auto_inicio),
  check (chefia_fim  is null or chefia_inicio  is null or chefia_fim  >= chefia_inicio)
);
alter table public.aval_periodos enable row level security;
drop policy if exists aval_periodos_ler on public.aval_periodos;
create policy aval_periodos_ler on public.aval_periodos
  for select to authenticated using (escola_id = minha_escola() and not sou_familia());
drop policy if exists aval_periodos_gerir on public.aval_periodos;
create policy aval_periodos_gerir on public.aval_periodos
  for all to authenticated
  using (escola_id = minha_escola() and (sou_rh() or sou_gestor_dir()))
  with check (escola_id = minha_escola() and (sou_rh() or sou_gestor_dir()));
drop trigger if exists trg_auditoria_servidor on public.aval_periodos;
create trigger trg_auditoria_servidor after insert or update or delete on public.aval_periodos
  for each row execute function public.auditoria_servidor();

create or replace function public.aval_hoje()
returns date language sql stable as $f$ select (now() at time zone 'Africa/Maputo')::date $f$;

-- fase: 'revisao' | 'auto' | 'chefia'
create or replace function public.aval_fase_aberta(p_escola uuid, p_ano int, p_fase text)
returns boolean language sql stable security definer set search_path to 'public' as $f$
  select coalesce((
    select case p_fase
             when 'revisao' then aval_hoje() between revisao_inicio and revisao_fim
             when 'auto'    then aval_hoje() between auto_inicio    and auto_fim
             when 'chefia'  then aval_hoje() between chefia_inicio  and chefia_fim
           end
      from public.aval_periodos where escola_id = p_escola and ano = p_ano), false)
$f$;

-- ── as acções passam a respeitar o calendário ───────────────────────────
create or replace function public.aval_submeter_auto(p_ano int, p_resp jsonb, p_comentario text)
returns text language plpgsql security definer set search_path to 'public' as $f$
declare r public.avaliacoes_desempenho;
begin
  select * into r from public.avaliacoes_desempenho
   where escola_id = minha_escola() and staff_id = meu_staff_id() and ano = p_ano;
  if not found then raise exception 'Ainda não há avaliação aberta para %.', p_ano; end if;
  if not aval_fase_aberta(r.escola_id, r.ano, 'auto') then
    raise exception 'A auto-avaliação não está a decorrer. O RH indica as datas.';
  end if;
  if r.estado <> 'aberta' then raise exception 'A auto-avaliação já não pode ser alterada.'; end if;
  if not aval_completa(r.grelha, p_resp) then raise exception 'Responda a todos os critérios (1 a 5).'; end if;
  update public.avaliacoes_desempenho
     set auto = jsonb_build_object('respostas', p_resp, 'comentario', left(coalesce(p_comentario, ''), 2000), 'em', now()),
         estado = 'auto_feita'
   where id = r.id;
  return 'ok';
end $f$;

create or replace function public.aval_guardar_chefia(p_id uuid, p_resp jsonb, p_comentario text,
                                                      p_fortes text, p_melhorar text, p_submeter boolean)
returns text language plpgsql security definer set search_path to 'public' as $f$
declare r public.avaliacoes_desempenho; n numeric;
begin
  select * into r from public.avaliacoes_desempenho where id = p_id and escola_id = minha_escola();
  if not found or not aval_pode_chefiar(r.staff_id) then raise exception 'Sem permissão para avaliar este funcionário.'; end if;
  if not (sou_rh() or sou_gestor_dir()) and not aval_fase_aberta(r.escola_id, r.ano, 'chefia') then
    raise exception 'A avaliação pelas chefias não está a decorrer. O RH indica as datas.';
  end if;
  if r.estado in ('validada','conhecimento') then raise exception 'Avaliação já validada.'; end if;
  if p_submeter and not aval_completa(r.grelha, p_resp) then raise exception 'Avalie todos os critérios (1 a 5) antes de submeter.'; end if;
  n := aval_nota(r.grelha, p_resp);
  update public.avaliacoes_desempenho
     set chefia = jsonb_build_object('respostas', coalesce(p_resp, '{}'::jsonb),
                    'comentario', left(coalesce(p_comentario, ''), 3000),
                    'pontos_fortes', left(coalesce(p_fortes, ''), 2000),
                    'a_melhorar', left(coalesce(p_melhorar, ''), 2000),
                    'por', aval_meu_nome(), 'em', now(), 'submetida', p_submeter),
         indicadores = aval_indicadores(r.staff_id, r.ano),
         estado = case when p_submeter then 'chefia_feita' else r.estado end,
         nota_final = case when p_submeter then n else r.nota_final end,
         classificacao = case when p_submeter then aval_classificacao(n) else r.classificacao end,
         devolvida_motivo = case when p_submeter then null else r.devolvida_motivo end
   where id = r.id;
  return 'ok';
end $f$;

create or replace function public.aval_revisao(p_id uuid, p_data date, p_notas text)
returns text language plpgsql security definer set search_path to 'public' as $f$
declare r public.avaliacoes_desempenho;
begin
  select * into r from public.avaliacoes_desempenho where id = p_id and escola_id = minha_escola();
  if not found or not aval_pode_chefiar(r.staff_id) then raise exception 'Sem permissão.'; end if;
  if not (sou_rh() or sou_gestor_dir()) and not aval_fase_aberta(r.escola_id, r.ano, 'revisao') then
    raise exception 'A revisão de meio do ano não está a decorrer. O RH indica as datas.';
  end if;
  if r.estado in ('validada','conhecimento') then raise exception 'Avaliação já validada.'; end if;
  update public.avaliacoes_desempenho
     set revisao = jsonb_build_object('data', p_data, 'notas', left(coalesce(p_notas, ''), 3000),
                                      'por', aval_meu_nome(), 'em', now())
   where id = r.id;
  return 'ok';
end $f$;

-- ── o que cada pessoa tem por fazer agora ────────────────────────────────
create or replace function public.aval_alertas(p_ano int)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $f$
declare p public.aval_periodos; eu uuid := meu_staff_id(); esc uuid := minha_escola(); v jsonb;
begin
  if esc is null then return null; end if;
  select * into p from public.aval_periodos where escola_id = esc and ano = p_ano;
  v := jsonb_build_object(
    'ano', p_ano, 'hoje', aval_hoje(), 'mensagem', p.mensagem,
    'fases', jsonb_build_object(
       'revisao', jsonb_build_object('inicio', p.revisao_inicio, 'fim', p.revisao_fim, 'aberta', aval_fase_aberta(esc, p_ano, 'revisao')),
       'auto',    jsonb_build_object('inicio', p.auto_inicio,    'fim', p.auto_fim,    'aberta', aval_fase_aberta(esc, p_ano, 'auto')),
       'chefia',  jsonb_build_object('inicio', p.chefia_inicio,  'fim', p.chefia_fim,  'aberta', aval_fase_aberta(esc, p_ano, 'chefia'))),
    'minha_estado', (select estado from public.avaliacoes_desempenho where escola_id = esc and staff_id = eu and ano = p_ano),
    'equipa_por_avaliar', (select count(*) from public.avaliacoes_desempenho a join public.staff s on s.id = a.staff_id
                            where a.escola_id = esc and a.ano = p_ano and s.chefe_id = eu and s.id <> eu
                              and a.estado in ('aberta','auto_feita')),
    'equipa_sem_revisao', (select count(*) from public.avaliacoes_desempenho a join public.staff s on s.id = a.staff_id
                            where a.escola_id = esc and a.ano = p_ano and s.chefe_id = eu and s.id <> eu
                              and a.revisao is null and a.estado in ('aberta','auto_feita')));
  return v;
end $f$;

revoke all on function public.aval_alertas(int), public.aval_fase_aberta(uuid, int, text) from public, anon;
grant execute on function public.aval_alertas(int) to authenticated;
