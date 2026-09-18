-- Scholaris (iQRA) — v6.213: Renovações e Inscrições para o ano seguinte.
-- Acrescenta colunas e o ano de 2027. Não apaga nem altera dados existentes.
-- ALTER TYPE ... ADD VALUE não corre dentro de transacção: fica à parte, no fim.

begin;

-- 1) Ano lectivo activo (funções usadas pelos valores por omissão)
create or replace function public.ano_lectivo_activo_id()
returns uuid language sql stable security definer set search_path to 'public' as $$
  select al.id
  from public.anos_lectivos al
  join public.escolas e on e.id = al.escola_id
  where al.escola_id = public.minha_escola()
  order by (al.ano = coalesce(e.config->>'anoLectivo', '')) desc, al.ativo desc, al.ano desc
  limit 1
$$;

create or replace function public.ano_lectivo_activo()
returns integer language sql stable security definer set search_path to 'public' as $$
  select nullif(regexp_replace(al.ano, '[^0-9]', '', 'g'), '')::int
  from public.anos_lectivos al
  where al.id = public.ano_lectivo_activo_id()
$$;

-- 2) Ano lectivo seguinte (2027), inactivo
insert into public.anos_lectivos (escola_id, ano, data_inicio, data_fim, ativo)
select e.id, '2027', date '2027-01-01', date '2027-12-31', false
  from public.escolas e
 where not exists (select 1 from public.anos_lectivos al
                    where al.escola_id = e.id and regexp_replace(al.ano, '[^0-9]', '', 'g') = '2027');

-- 3) Matrícula por classe: a turma passa a ser opcional e guarda-se a classe
alter table public.matriculas alter column turma_id drop not null;
alter table public.matriculas add column if not exists classe smallint;
alter table public.matriculas add column if not exists registado_por text;
alter table public.matriculas add column if not exists aprovado_por text;
alter table public.matriculas add column if not exists aprovado_em timestamptz;
update public.matriculas m set classe = t.classe
  from public.turmas t where m.turma_id = t.id and m.classe is null;

-- 4) Ano do pagamento (o que já existe fica em 2026, o ano em curso)
alter table public.pagamentos add column if not exists ano integer;
update public.pagamentos set ano = coalesce(nullif(left(coalesce(data_pag::text, ''), 4), '')::int, 2026) where ano is null;
alter table public.pagamentos alter column ano set default public.ano_lectivo_activo();
create index if not exists idx_pagamentos_ano on public.pagamentos(escola_id, ano);

-- 5) Candidaturas por ano
alter table public.candidaturas add column if not exists ano integer;
update public.candidaturas c set ano = (e.config->>'anoLectivo')::int
  from public.escolas e where c.escola_id = e.id and c.ano is null and (e.config->>'anoLectivo') ~ '^[0-9]{4}$';

-- 6) Preçário por ano (2026 = o que está em uso; 2027 = cópia, para ajustar depois) e renovações abertas
update public.escolas e set config = jsonb_set(e.config, '{precarios}', '{}'::jsonb, true)
  where not (e.config ? 'precarios');
update public.escolas e set config = jsonb_set(e.config, '{precarios,2026}', e.config->'valoresPorClasse', true)
  where (e.config ? 'valoresPorClasse') and not (e.config->'precarios' ? '2026');
update public.escolas e set config = jsonb_set(e.config, '{precarios,2027}', e.config->'precarios'->'2026', true)
  where (e.config->'precarios' ? '2026') and not (e.config->'precarios' ? '2027');
update public.escolas e set config = jsonb_set(e.config, '{renovacoes}', '{"fechado": false}'::jsonb, true)
  where not (e.config ? 'renovacoes');

commit;

-- 7) Estados novos da matrícula (a inscrição fica pendente até a direcção aprovar)
alter type public.estado_matricula add value if not exists 'pendente';
alter type public.estado_matricula add value if not exists 'rejeitada';

notify pgrst, 'reload schema';
