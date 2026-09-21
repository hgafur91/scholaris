-- Scholaris (Colégio iQRA) — v6.226: campanhas de isenção de matrícula e renovação.
--
-- A direcção (director ou gestor) activa um período em que quem se inscreve ou
-- renova fica isento da matrícula (alunos novos), da renovação (quem já é aluno),
-- ou das duas. Todas as classes.
--
-- A isenção fica gravada na MATRÍCULA desse ano, não no aluno: as marcas de
-- isenção das Bolsas (`alunos.isento_*`) são permanentes, e usá-las aqui isentaria
-- o aluno também nos anos seguintes.
--
-- Nota de vocabulário: no iQRA não há taxa de inscrição. O campo `inscricao` do
-- preçário guarda a RENOVAÇÃO (2 575 / 2 680); `matricula` é a do aluno novo (4 255).

begin;

-- ════════════════════════════════════════════════════════════════════════
-- 1) Campanhas
-- ════════════════════════════════════════════════════════════════════════

create table if not exists public.campanhas_isencao (
  id               uuid primary key default gen_random_uuid(),
  escola_id        uuid not null references public.escolas(id) on delete cascade,
  nome             text not null,
  isenta_matricula boolean not null default false,
  isenta_renovacao boolean not null default false,
  inicio           date not null,
  fim              date not null,
  criada_por       text,
  criada_em        timestamptz not null default now(),
  encerrada_em     timestamptz,
  encerrada_por    text,
  constraint campanha_nome   check (length(trim(nome)) > 0),
  constraint campanha_datas  check (fim >= inicio),
  constraint campanha_isenta check (isenta_matricula or isenta_renovacao)
);

create index if not exists idx_campanhas_escola on public.campanhas_isencao(escola_id, inicio);

comment on table public.campanhas_isencao is
  'Períodos em que a direcção isenta a matrícula e/ou a renovação a quem se inscreve ou renova.';

alter table public.campanhas_isencao enable row level security;
revoke all on public.campanhas_isencao from anon, authenticated;
grant select, insert, update on public.campanhas_isencao to authenticated;

drop policy if exists campanhas_ler     on public.campanhas_isencao;
drop policy if exists campanhas_criar   on public.campanhas_isencao;
drop policy if exists campanhas_alterar on public.campanhas_isencao;

-- O pessoal administrativo vê (o secretário precisa de saber que há campanha)…
create policy campanhas_ler on public.campanhas_isencao for select to authenticated
  using ( escola_id = public.minha_escola() and public.sou_admin() );

-- …mas só o director e o gestor criam e encerram.
create policy campanhas_criar on public.campanhas_isencao for insert to authenticated
  with check ( escola_id = public.minha_escola() and public.sou_gestor_dir() );

create policy campanhas_alterar on public.campanhas_isencao for update to authenticated
  using      ( escola_id = public.minha_escola() and public.sou_gestor_dir() )
  with check ( escola_id = public.minha_escola() and public.sou_gestor_dir() );

-- Uma campanha de cada vez: duas campanhas por encerrar não se podem sobrepor,
-- e uma campanha nova não começa no passado.
create or replace function public.campanha_isencao_valida()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
declare hoje date := (now() at time zone 'Africa/Maputo')::date;
begin
  if tg_op = 'INSERT' and new.inicio < hoje then
    raise exception 'A campanha não pode começar antes de hoje';
  end if;
  if tg_op = 'UPDATE' then
    -- depois de criada, só se pode encerrar: nome, tipo e datas não mudam
    if new.nome is distinct from old.nome
       or new.isenta_matricula is distinct from old.isenta_matricula
       or new.isenta_renovacao is distinct from old.isenta_renovacao
       or new.inicio is distinct from old.inicio
       or new.fim    is distinct from old.fim
       or new.escola_id is distinct from old.escola_id then
      raise exception 'Uma campanha criada não se altera: encerre-a e crie outra';
    end if;
    if old.encerrada_em is not null then
      raise exception 'Esta campanha já foi encerrada';
    end if;
    return new;
  end if;
  if exists (
    select 1 from public.campanhas_isencao c
     where c.escola_id = new.escola_id
       and c.id <> new.id
       and c.encerrada_em is null
       and daterange(c.inicio, c.fim, '[]') && daterange(new.inicio, new.fim, '[]')
  ) then
    raise exception 'Já existe uma campanha nesse período';
  end if;
  return new;
end
$fn$;

drop trigger if exists trg_campanha_isencao_valida on public.campanhas_isencao;
create trigger trg_campanha_isencao_valida
  before insert or update on public.campanhas_isencao
  for each row execute function public.campanha_isencao_valida();

-- ════════════════════════════════════════════════════════════════════════
-- 2) A isenção fica na matrícula desse ano
-- ════════════════════════════════════════════════════════════════════════

alter table public.matriculas add column if not exists isenta_matricula boolean not null default false;
alter table public.matriculas add column if not exists isenta_renovacao boolean not null default false;
alter table public.matriculas add column if not exists campanha_id uuid references public.campanhas_isencao(id);

-- A base de dados só aceita a isenção se houver uma campanha activa HOJE que a
-- cubra. Sem isto, quem tem acesso às renovações podia isentar por fora, pela API.
-- A direcção pode isentar à mão (sem campanha); a chave de administração passa.
create or replace function public.matricula_isencao_valida()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
declare
  c    public.campanhas_isencao%rowtype;
  hoje date := (now() at time zone 'Africa/Maputo')::date;
begin
  if not (new.isenta_matricula or new.isenta_renovacao) then
    return new;
  end if;
  -- aprovar, rejeitar ou pôr turma não mexe na isenção já dada
  if tg_op = 'UPDATE'
     and new.isenta_matricula = old.isenta_matricula
     and new.isenta_renovacao = old.isenta_renovacao
     and new.campanha_id is not distinct from old.campanha_id then
    return new;
  end if;
  if auth.uid() is null then return new; end if;
  if new.campanha_id is null then
    if public.sou_gestor_dir() then return new; end if;
    raise exception 'Isenção sem campanha: só a direcção pode isentar à mão';
  end if;
  select * into c from public.campanhas_isencao
   where id = new.campanha_id and escola_id = new.escola_id;
  if not found then
    raise exception 'Campanha de isenção inexistente';
  end if;
  if c.encerrada_em is not null or hoje < c.inicio or hoje > c.fim then
    raise exception 'A campanha «%» não está activa hoje', c.nome;
  end if;
  if (new.isenta_matricula and not c.isenta_matricula)
     or (new.isenta_renovacao and not c.isenta_renovacao) then
    raise exception 'A campanha «%» não cobre esta isenção', c.nome;
  end if;
  return new;
end
$fn$;

drop trigger if exists trg_matricula_isencao_valida on public.matriculas;
create trigger trg_matricula_isencao_valida
  before insert or update on public.matriculas
  for each row execute function public.matricula_isencao_valida();

commit;

notify pgrst, 'reload schema';
