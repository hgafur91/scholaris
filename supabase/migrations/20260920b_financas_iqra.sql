-- Scholaris (Colégio iQRA) — v6.223, parte 1 de 2: tirar o que é confidencial das
-- tabelas que toda a gente tem de ler.
--
-- `escolas.config` é lido por qualquer pessoa com sessão (preçário, períodos,
-- trimestres), e lá dentro viviam as folhas de salários e as contas bancárias.
-- A tabela `staff` é lida pelo pessoal administrativo pelos nomes e cargos, e lá
-- dentro vivia o ordenado.
--
-- Este ficheiro só CRIA e COPIA. A limpeza vai no ficheiro seguinte, depois de a
-- aplicação já ler e gravar no sítio novo.

begin;

-- ════════════════════════════════════════════════════════════════════════
-- 1) Folhas de salários e contas bancárias da escola
-- ════════════════════════════════════════════════════════════════════════

create table if not exists public.escola_financas (
  escola_id      uuid primary key references public.escolas(id) on delete cascade,
  folhas         jsonb       not null default '{}'::jsonb,
  contas_banco   jsonb       not null default '{}'::jsonb,
  actualizado_em timestamptz not null default now(),
  actualizado_por text
);

comment on table public.escola_financas is
  'Folhas de salários e contas bancárias da escola. Fora de escolas.config porque essa coluna é lida por todos os utilizadores.';

alter table public.escola_financas enable row level security;
revoke all on public.escola_financas from anon, authenticated;
grant select, insert, update on public.escola_financas to authenticated;

drop policy if exists financas_ler      on public.escola_financas;
drop policy if exists financas_escrever on public.escola_financas;

create policy financas_ler on public.escola_financas for select to authenticated
  using ( escola_id = public.minha_escola() and public.sou_gestor_dir() );

create policy financas_escrever on public.escola_financas for all to authenticated
  using      ( escola_id = public.minha_escola() and public.sou_gestor_dir() )
  with check ( escola_id = public.minha_escola() and public.sou_gestor_dir() );

insert into public.escola_financas (escola_id, folhas, contas_banco)
select e.id,
       coalesce(e.config->'folhas', '{}'::jsonb),
       coalesce(e.config->'contasBanco', '{}'::jsonb)
  from public.escolas e
on conflict (escola_id) do update
  set folhas         = excluded.folhas,
      contas_banco   = excluded.contas_banco,
      actualizado_em = now();

-- ════════════════════════════════════════════════════════════════════════
-- 2) Salário e documentos do pessoal
-- ════════════════════════════════════════════════════════════════════════

create table if not exists public.staff_confidencial (
  staff_id        uuid primary key references public.staff(id) on delete cascade,
  escola_id       uuid not null references public.escolas(id) on delete cascade,
  salario         numeric,
  subsidio_cargo  numeric,
  iban            text,
  banco           text,
  bi              text,
  niss            text,
  nuit            text,
  actualizado_em  timestamptz not null default now(),
  actualizado_por text
);

create index if not exists idx_staff_conf_escola on public.staff_confidencial(escola_id);

comment on table public.staff_confidencial is
  'Salário e documentos do pessoal. Fora da tabela staff porque essa é lida por todo o pessoal administrativo.';

alter table public.staff_confidencial enable row level security;
revoke all on public.staff_confidencial from anon, authenticated;
grant select, insert, update, delete on public.staff_confidencial to authenticated;

drop policy if exists staffconf_ler      on public.staff_confidencial;
drop policy if exists staffconf_escrever on public.staff_confidencial;

create policy staffconf_ler on public.staff_confidencial for select to authenticated
  using ( escola_id = public.minha_escola()
          and ( public.sou_gestor_dir() or staff_id = public.meu_staff_id() ) );

create policy staffconf_escrever on public.staff_confidencial for all to authenticated
  using      ( escola_id = public.minha_escola() and public.sou_gestor_dir() )
  with check ( escola_id = public.minha_escola() and public.sou_gestor_dir() );

insert into public.staff_confidencial
       (staff_id, escola_id, salario, subsidio_cargo, iban, banco, bi, niss, nuit)
select s.id, s.escola_id, s.salario, s.subsidio_cargo, s.iban, s.banco, s.bi, s.niss, s.nuit
  from public.staff s
on conflict (staff_id) do update
  set salario        = excluded.salario,
      subsidio_cargo = excluded.subsidio_cargo,
      iban           = excluded.iban,
      banco          = excluded.banco,
      bi             = excluded.bi,
      niss           = excluded.niss,
      nuit           = excluded.nuit,
      actualizado_em = now();

commit;

notify pgrst, 'reload schema';
