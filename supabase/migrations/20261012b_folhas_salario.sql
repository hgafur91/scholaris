-- ═══════════════════════════════════════════════════════════════════════
--  Scholaris — folha de salários em tabela própria, com fecho trancado
--  (fase 2 do módulo de RH) · 2026-10-12 · app v6.252 (iQRA) / v6.271
--  (Atlântico). Serve para as duas escolas. Idempotente.
--
--  Antes: todas as folhas viviam num único JSON (escola_financas.folhas),
--  gravado por inteiro de cada vez; "aprovar" era só uma marca nesse JSON,
--  que qualquer gravação seguinte podia desfazer.
--  Agora:
--   · uma linha por escola/ano/mês em folhas_salario (dados = o mesmo objecto
--     que a app já usa: linhas, parciais, geradaEm…);
--   · estado rascunho → fechada. Fechada fica TRANCADA no servidor: ninguém a
--     altera; só a direcção (gestor/director) a reabre;
--   · quem fecha e quando é gravado pelo servidor, não pelo browser;
--   · a direcção e o Gestor de RH preparam, fecham e imprimem; o RH também lê
--     e grava as contas bancárias dos funcionários (escola_financas) e a linha
--     de despesa «salários» que o fecho manda para o balancete;
--   · cada alteração fica na auditoria do servidor.
--  A coluna escola_financas.folhas fica como cópia de segurança (a app deixa
--  de a usar).
-- ═══════════════════════════════════════════════════════════════════════

create table if not exists public.folhas_salario (
  id              uuid primary key default gen_random_uuid(),
  escola_id       uuid not null references public.escolas(id) on delete cascade,
  ano             int  not null,
  mes             int  not null check (mes between 1 and 12),
  dados           jsonb not null default '{}'::jsonb,
  estado          text not null default 'rascunho' check (estado in ('rascunho','fechada')),
  fechada_por     text,
  fechada_em      timestamptz,
  actualizado_em  timestamptz not null default now(),
  actualizado_por text,
  unique (escola_id, ano, mes)
);
alter table public.folhas_salario enable row level security;

-- ── Quem lê e escreve: direcção e Gestor de RH (ninguém apaga pela app) ──
drop policy if exists folhas_ler on public.folhas_salario;
create policy folhas_ler on public.folhas_salario
  for select to authenticated
  using (escola_id = minha_escola() and (sou_gestor_dir() or sou_rh()));
drop policy if exists folhas_criar on public.folhas_salario;
create policy folhas_criar on public.folhas_salario
  for insert to authenticated
  with check (escola_id = minha_escola() and (sou_gestor_dir() or sou_rh()));
drop policy if exists folhas_alterar on public.folhas_salario;
create policy folhas_alterar on public.folhas_salario
  for update to authenticated
  using (escola_id = minha_escola() and (sou_gestor_dir() or sou_rh()))
  with check (escola_id = minha_escola() and (sou_gestor_dir() or sou_rh()));

-- ── Tranca: fechada não se altera; só a direcção reabre ──────────────────
create or replace function public.folhas_salario_tranca()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $f$
declare
  quem text;
begin
  if auth.uid() is not null then
    select coalesce(nome_completo, id::text) into quem from public.perfis where id = auth.uid();
  end if;
  new.actualizado_em := now();
  new.actualizado_por := coalesce(quem, new.actualizado_por);

  if tg_op = 'UPDATE' and old.estado = 'fechada' and auth.uid() is not null then
    if new.estado = 'rascunho' and public.sou_gestor_dir() then
      new.fechada_por := null;             -- reaberta pela direcção
      new.fechada_em  := null;
      return new;
    end if;
    raise exception 'A folha de %/% está fechada. Só a direcção a pode reabrir.', old.mes, old.ano;
  end if;

  if new.estado = 'fechada' and (tg_op = 'INSERT' or old.estado <> 'fechada') then
    if auth.uid() is not null or new.fechada_em is null then
      new.fechada_em := now();             -- carimbo do servidor, não do browser
    end if;                                -- (a migração mantém a data original)
    new.fechada_por := coalesce(quem, new.fechada_por);
  end if;
  return new;
end
$f$;

drop trigger if exists trg_folhas_tranca on public.folhas_salario;
create trigger trg_folhas_tranca
  before insert or update on public.folhas_salario
  for each row execute function public.folhas_salario_tranca();

drop trigger if exists trg_auditoria_servidor on public.folhas_salario;
create trigger trg_auditoria_servidor
  after insert or update or delete on public.folhas_salario
  for each row execute function public.auditoria_servidor();

-- ── Passar as folhas que já existem (estado: aprovada → fechada) ─────────
insert into public.folhas_salario (escola_id, ano, mes, dados, estado, fechada_por, fechada_em, actualizado_por)
select f.escola_id,
       a.key::int,
       m.key::int,
       m.value - 'status' - 'aprovadaPor' - 'aprovadaEm',
       case when m.value->>'status' = 'aprovada' then 'fechada' else 'rascunho' end,
       nullif(m.value->>'aprovadaPor', ''),
       case when m.value->>'aprovadaEm' ~ '^\d{4}-' then (m.value->>'aprovadaEm')::timestamptz end,
       'migração 20261012b'
  from public.escola_financas f,
       jsonb_each(coalesce(f.folhas, '{}'::jsonb)) a,
       jsonb_each(a.value) m
 where a.key ~ '^\d{4}$' and m.key ~ '^\d{1,2}$' and jsonb_typeof(m.value) = 'object'
on conflict (escola_id, ano, mes) do nothing;

-- ── Contas bancárias dos funcionários (escola_financas.contas_banco) ─────
drop policy if exists financas_rh on public.escola_financas;
create policy financas_rh on public.escola_financas
  for all to authenticated
  using (escola_id = minha_escola() and sou_rh())
  with check (escola_id = minha_escola() and sou_rh());

-- ── Linha «salários» do balancete, escrita quando a folha fecha ──────────
drop policy if exists despesas_rh_salarios on public.despesas;
create policy despesas_rh_salarios on public.despesas
  for all to authenticated
  using (escola_id = (minha_escola())::text and sou_rh() and categoria = 'salarios')
  with check (escola_id = (minha_escola())::text and sou_rh() and categoria = 'salarios');
