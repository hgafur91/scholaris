-- ═══════════════════════════════════════════════════════════════════════
--  Scholaris — Ponto (entradas e saídas) e atrasos do pessoal
--  2026-10-14 · app v6.261 (iQRA) / v6.280 (Atlântico). Serve para as duas
--  escolas. Idempotente.
--
--  Cada funcionário tem um cartão com um QR secreto. Na portaria há um
--  aparelho em «Modo Ponto» (câmara ou leitor USB) com uma conta própria,
--  de papel «portaria», que só consegue registar pontos: a 1.ª leitura do
--  dia é a entrada, a seguinte a saída. O atraso calcula-se sozinho pela
--  hora de entrada (geral da escola ou própria do funcionário) e tolerância.
--  O RH e a direcção vêem, corrigem, justificam e registam à mão.
--  Na avaliação de desempenho, N atrasos injustificados (defeito 3) contam
--  como 1 falta para o nível sugerido de assiduidade.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1) Papel «portaria» ─────────────────────────────────────────────────
alter type public.perfil_utilizador add value if not exists 'portaria';

-- compara como texto: o valor novo do enum só pode ser usado depois do commit
create or replace function public.sou_portaria()
returns boolean language sql stable security definer set search_path to 'public' as $f$
  select exists(select 1 from public.perfis
                 where id = auth.uid() and perfil::text = 'portaria')
$f$;

-- ── 2) Configuração da escola ───────────────────────────────────────────
create table if not exists public.ponto_config (
  escola_id         uuid primary key references public.escolas(id) on delete cascade,
  hora_entrada      time     not null default '07:30',
  tolerancia_min    smallint not null default 10 check (tolerancia_min between 0 and 120),
  atrasos_por_falta smallint not null default 3  check (atrasos_por_falta between 1 and 20),
  updated_at        timestamptz not null default now(),
  updated_by        uuid default auth.uid()
);

-- ── 3) Cartão e horário de cada funcionário ─────────────────────────────
create table if not exists public.ponto_pessoal (
  staff_id          uuid primary key references public.staff(id) on delete cascade,
  escola_id         uuid not null references public.escolas(id) on delete cascade,
  codigo            text unique check (codigo is null or codigo ~ '^[0-9A-F]{32}$'),
  codigo_emitido_em timestamptz,
  hora_entrada      time,                    -- vazio = hora geral da escola
  tolerancia_min    smallint check (tolerancia_min is null or tolerancia_min between 0 and 120),
  isento            boolean not null default false,   -- não conta atrasos (ex.: direcção)
  updated_at        timestamptz not null default now()
);
create index if not exists ponto_pessoal_escola on public.ponto_pessoal (escola_id);

-- ── 4) Registos (um por pessoa por dia) ─────────────────────────────────
create table if not exists public.ponto_registos (
  id            uuid primary key default gen_random_uuid(),
  escola_id     uuid not null references public.escolas(id) on delete cascade,
  staff_id      uuid not null references public.staff(id) on delete cascade,
  data          date not null,
  entrada       timestamptz,
  saida         timestamptz,
  hora_prevista time,
  atraso_min    integer not null default 0 check (atraso_min >= 0),
  justificado   boolean not null default false,
  motivo        text check (motivo is null or length(motivo) <= 500),
  origem        text not null default 'qr' check (origem in ('qr','manual')),
  registado_por uuid default auth.uid(),
  alterado_por  uuid,
  alterado_em   timestamptz,
  created_at    timestamptz not null default now(),
  unique (staff_id, data),
  check (saida is null or entrada is null or saida >= entrada)
);
create index if not exists ponto_registos_escola_data on public.ponto_registos (escola_id, data);

-- escola, dia e atraso calculados no servidor (o cliente não os escolhe)
create or replace function public.ponto_calcular()
returns trigger language plpgsql security definer set search_path to 'public' as $f$
declare v_pp public.ponto_pessoal; v_cfg public.ponto_config; v_tol int; v_diff numeric;
begin
  select escola_id into new.escola_id from public.staff where id = new.staff_id;
  if new.escola_id is null then raise exception 'Funcionário desconhecido.'; end if;
  if tg_op = 'INSERT' and new.data is null then
    new.data := (coalesce(new.entrada, new.saida, now()) at time zone 'Africa/Maputo')::date;
  end if;
  if tg_op = 'UPDATE' then
    new.alterado_por := auth.uid(); new.alterado_em := now();
    new.registado_por := old.registado_por; new.created_at := old.created_at;
  end if;
  if tg_op = 'INSERT' or new.entrada is distinct from old.entrada then
    select * into v_pp  from public.ponto_pessoal where staff_id = new.staff_id;
    select * into v_cfg from public.ponto_config  where escola_id = new.escola_id;
    new.hora_prevista := coalesce(v_pp.hora_entrada, v_cfg.hora_entrada, '07:30'::time);
    v_tol := coalesce(v_pp.tolerancia_min, v_cfg.tolerancia_min, 10);
    new.atraso_min := 0;
    if new.entrada is not null and not coalesce(v_pp.isento, false) then
      v_diff := extract(epoch from ((new.entrada at time zone 'Africa/Maputo')::time - new.hora_prevista)) / 60;
      if v_diff > v_tol then new.atraso_min := floor(v_diff)::int; end if;
    end if;
  end if;
  if new.atraso_min = 0 then new.justificado := false; end if;
  return new;
end $f$;
drop trigger if exists ponto_registos_calcular on public.ponto_registos;
create trigger ponto_registos_calcular before insert or update on public.ponto_registos
  for each row execute function public.ponto_calcular();

-- ── 5) Permissões (RLS) ─────────────────────────────────────────────────
alter table public.ponto_config   enable row level security;
alter table public.ponto_pessoal  enable row level security;
alter table public.ponto_registos enable row level security;

drop policy if exists ponto_config_ver on public.ponto_config;
create policy ponto_config_ver on public.ponto_config for select to authenticated
  using (escola_id = minha_escola() and (sou_rh() or sou_gestor_dir()));
drop policy if exists ponto_config_gerir on public.ponto_config;
create policy ponto_config_gerir on public.ponto_config for all to authenticated
  using (escola_id = minha_escola() and (sou_rh() or sou_gestor_dir()))
  with check (escola_id = minha_escola() and (sou_rh() or sou_gestor_dir()));

-- os códigos dos cartões só o RH e a direcção os vêem
drop policy if exists ponto_pessoal_gerir on public.ponto_pessoal;
create policy ponto_pessoal_gerir on public.ponto_pessoal for all to authenticated
  using (escola_id = minha_escola() and (sou_rh() or sou_gestor_dir()))
  with check (escola_id = minha_escola() and (sou_rh() or sou_gestor_dir())
              and exists (select 1 from public.staff s where s.id = staff_id and s.escola_id = minha_escola()));

-- cada funcionário vê os seus registos; RH e direcção vêem e corrigem todos
drop policy if exists ponto_registos_ver on public.ponto_registos;
create policy ponto_registos_ver on public.ponto_registos for select to authenticated
  using (escola_id = minha_escola() and (sou_rh() or sou_gestor_dir() or staff_id = meu_staff_id()));
drop policy if exists ponto_registos_criar on public.ponto_registos;
create policy ponto_registos_criar on public.ponto_registos for insert to authenticated
  with check (sou_rh() or sou_gestor_dir());
drop policy if exists ponto_registos_alterar on public.ponto_registos;
create policy ponto_registos_alterar on public.ponto_registos for update to authenticated
  using (escola_id = minha_escola() and (sou_rh() or sou_gestor_dir()))
  with check (sou_rh() or sou_gestor_dir());
drop policy if exists ponto_registos_apagar on public.ponto_registos;
create policy ponto_registos_apagar on public.ponto_registos for delete to authenticated
  using (escola_id = minha_escola() and (sou_rh() or sou_gestor_dir()));
-- (a escola do registo vem sempre do funcionário, pelo gatilho; o funcionário
--  tem de ser da escola de quem grava)
drop policy if exists ponto_registos_mesma_escola on public.ponto_registos;
create policy ponto_registos_mesma_escola on public.ponto_registos as restrictive for all to authenticated
  using (escola_id = minha_escola())
  with check (exists (select 1 from public.staff s where s.id = staff_id and s.escola_id = minha_escola()));

-- auditoria do servidor (quem mexeu, quando)
do $$ begin
  if exists (select 1 from pg_proc where proname = 'auditoria_servidor') then
    execute 'drop trigger if exists auditoria_servidor on public.ponto_registos';
    execute 'create trigger auditoria_servidor after insert or update or delete on public.ponto_registos for each row execute function public.auditoria_servidor()';
  end if;
end $$;

-- ── 6) A conta da portaria não lê nem escreve nada directamente ─────────
-- Política restritiva em todas as tabelas: só passa por funções do servidor
-- (ponto_marcar, ponto_quiosque). No perfil vê apenas a própria linha.
do $$ declare t record; begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r','p') and c.relname <> 'perfis' loop
    execute format('drop policy if exists portaria_nada on public.%I', t.relname);
    execute format('create policy portaria_nada on public.%I as restrictive for all to authenticated '
                || 'using (not (select public.sou_portaria())) with check (not (select public.sou_portaria()))', t.relname);
  end loop;
end $$;
drop policy if exists portaria_so_propria on public.perfis;
create policy portaria_so_propria on public.perfis as restrictive for all to authenticated
  using (not (select public.sou_portaria()) or id = auth.uid())
  with check (not (select public.sou_portaria()));

-- ── 7) Funções ──────────────────────────────────────────────────────────
-- Modo Ponto: lê um cartão. 1.ª leitura do dia = entrada; seguinte = saída.
-- Uma segunda leitura com menos de 2 minutos é ignorada (cartão passado duas vezes).
create or replace function public.ponto_marcar(p_codigo text)
returns jsonb language plpgsql security definer set search_path to 'public' as $f$
declare
  v_escola uuid := minha_escola();
  v_cod text; v_pp public.ponto_pessoal; v_s public.staff; v_r public.ponto_registos;
  v_agora timestamptz := now();
  v_hoje date := (now() at time zone 'Africa/Maputo')::date;
  v_res text;
begin
  if not (sou_portaria() or sou_rh() or sou_gestor_dir()) then
    raise exception 'Sem permissão para registar o ponto.';
  end if;
  v_cod := upper(regexp_replace(coalesce(p_codigo, ''), '[^0-9A-Za-z]', '', 'g'));
  if v_cod like 'SCHP%' then v_cod := substr(v_cod, 5); end if;
  if v_cod !~ '^[0-9A-F]{32}$' then return jsonb_build_object('resultado', 'desconhecido'); end if;

  select * into v_pp from public.ponto_pessoal where codigo = v_cod and escola_id = v_escola;
  if not found then return jsonb_build_object('resultado', 'desconhecido'); end if;
  select * into v_s from public.staff where id = v_pp.staff_id;
  if not coalesce(v_s.ativo, true) then
    return jsonb_build_object('resultado', 'inactivo', 'nome', v_s.nome);
  end if;

  select * into v_r from public.ponto_registos where staff_id = v_s.id and data = v_hoje for update;
  if not found then
    insert into public.ponto_registos (escola_id, staff_id, data, entrada, origem)
    values (v_escola, v_s.id, v_hoje, v_agora, 'qr') returning * into v_r;
    v_res := 'entrada';
  elsif v_r.entrada is null then
    update public.ponto_registos set entrada = v_agora where id = v_r.id returning * into v_r;
    v_res := 'entrada';
  elsif v_agora - coalesce(v_r.saida, v_r.entrada) < interval '2 minutes' then
    v_res := 'repetido';
  else
    update public.ponto_registos set saida = v_agora where id = v_r.id returning * into v_r;
    v_res := 'saida';
  end if;

  return jsonb_build_object(
    'resultado', v_res, 'nome', v_s.nome, 'cargo', v_s.cargo, 'num', v_s.num,
    'entrada', to_char(v_r.entrada at time zone 'Africa/Maputo', 'HH24:MI'),
    'saida',   to_char(v_r.saida   at time zone 'Africa/Maputo', 'HH24:MI'),
    'prevista', to_char(v_r.hora_prevista, 'HH24:MI'), 'atraso_min', v_r.atraso_min);
end $f$;

-- Modo Ponto: nome da escola e quantos já entraram hoje
create or replace function public.ponto_quiosque()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $f$
begin
  if not (sou_portaria() or sou_rh() or sou_gestor_dir()) then
    raise exception 'Sem permissão.';
  end if;
  return jsonb_build_object(
    'escola', (select nome from public.escolas where id = minha_escola()),
    'entradas_hoje', (select count(*) from public.ponto_registos
                       where escola_id = minha_escola() and entrada is not null
                         and data = (now() at time zone 'Africa/Maputo')::date));
end $f$;

-- RH: dá cartão a quem ainda não tem (todo o pessoal activo); devolve quantos criou
create or replace function public.ponto_garantir_cartoes()
returns int language plpgsql security definer set search_path to 'public' as $f$
declare n int;
begin
  if not (sou_rh() or sou_gestor_dir()) then raise exception 'Só o RH ou a direcção emitem cartões.'; end if;
  insert into public.ponto_pessoal (staff_id, escola_id)
  select s.id, s.escola_id from public.staff s
   where s.escola_id = minha_escola() and coalesce(s.ativo, true)
  on conflict (staff_id) do nothing;
  update public.ponto_pessoal
     set codigo = upper(replace(gen_random_uuid()::text, '-', '')), codigo_emitido_em = now(), updated_at = now()
   where escola_id = minha_escola() and codigo is null;
  get diagnostics n = row_count;
  return n;
end $f$;

-- RH: cartão perdido → código novo; o antigo deixa de funcionar
create or replace function public.ponto_novo_cartao(p_staff uuid)
returns text language plpgsql security definer set search_path to 'public' as $f$
declare v_cod text := upper(replace(gen_random_uuid()::text, '-', ''));
begin
  if not (sou_rh() or sou_gestor_dir()) then raise exception 'Só o RH ou a direcção emitem cartões.'; end if;
  if not exists (select 1 from public.staff where id = p_staff and escola_id = minha_escola()) then
    raise exception 'Funcionário de outra escola.';
  end if;
  insert into public.ponto_pessoal (staff_id, escola_id, codigo, codigo_emitido_em)
  values (p_staff, minha_escola(), v_cod, now())
  on conflict (staff_id) do update set codigo = excluded.codigo, codigo_emitido_em = now(), updated_at = now();
  return v_cod;
end $f$;

-- ── 8) Avaliação: atrasos entram na assiduidade ─────────────────────────
-- nível sugerido conta faltas injustificadas + (atrasos injustificados ÷ N)
create or replace function public.aval_indicadores(p_staff uuid, p_ano int)
returns jsonb language sql stable security definer set search_path to 'public' as $f$
  with f as (
    select count(*) filter (where not coalesce(justif, false)) inj,
           count(*) filter (where coalesce(justif, false))     jus
      from public.faltas where staff_id = p_staff and extract(year from data) = p_ano
  ), a as (
    select count(*) filter (where not justificado) inj,
           count(*) filter (where justificado)     jus,
           coalesce(sum(atraso_min) filter (where not justificado), 0) mins
      from public.ponto_registos
     where staff_id = p_staff and extract(year from data) = p_ano and atraso_min > 0
  ), c as (
    select coalesce((select pc.atrasos_por_falta from public.ponto_config pc
                       join public.staff s on s.escola_id = pc.escola_id
                      where s.id = p_staff), 3)::int apf
  ), t as (select f.inj + a.inj / c.apf eq from f, a, c)
  select jsonb_build_object(
    'assiduidade', jsonb_build_object('injustificadas', f.inj, 'justificadas', f.jus,
       'atrasos', a.inj, 'atrasos_justificados', a.jus, 'minutos_atraso', a.mins,
       'atrasos_por_falta', c.apf, 'equivalentes', t.eq,
       'nivel', case when t.eq = 0 then 5 when t.eq <= 2 then 4 when t.eq <= 5 then 3
                     when t.eq <= 9 then 2 else 1 end),
    'sumarios', jsonb_build_object('aulas', (select count(*) from public.aulas_dadas
                                              where professor_id = p_staff and extract(year from data) = p_ano)))
    from f, a, c, t
$f$;

-- ── 9) Execução ─────────────────────────────────────────────────────────
revoke all on function public.sou_portaria(), public.ponto_marcar(text), public.ponto_quiosque(),
  public.ponto_garantir_cartoes(), public.ponto_novo_cartao(uuid), public.ponto_calcular(),
  public.aval_indicadores(uuid, int) from public, anon;
grant execute on function public.sou_portaria(), public.ponto_marcar(text), public.ponto_quiosque(),
  public.ponto_garantir_cartoes(), public.ponto_novo_cartao(uuid) to authenticated;
revoke all on table public.ponto_config, public.ponto_pessoal, public.ponto_registos from anon;
