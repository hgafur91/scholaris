-- ═══════════════════════════════════════════════════════════════════════
--  Scholaris — Ponto: reforço depois da revisão de segurança
--  2026-10-14 · iQRA v6.261 / Atlântico v6.280. Serve para as duas escolas.
--  Idempotente.
--
--  1) A conta da portaria deixa de «ter escola» para o resto do sistema:
--     minha_escola() devolve nulo para ela. Assim nenhuma função antiga,
--     política ou pasta de ficheiros (todas filtram por minha_escola()) lhe
--     dá acesso. Só as funções do ponto conhecem a escola dela.
--  2) Três vistas antigas (não usadas pela app, vazias) corriam com os
--     direitos do dono e ignoravam o RLS, incluindo para a chave anónima.
--  3) aval_indicadores só por dentro das funções da avaliação.
--  4) Gatilho do ponto: atraso em minutos inteiros; numa correcção o atraso
--     só muda se mudar a entrada; origem e autor não se escolhem; não se
--     registam horas no futuro.
--  5) ponto_marcar: 10 minutos entre entrada e saída (cartão esquecido à
--     frente da câmara) e sem erro se duas leituras chegarem ao mesmo tempo.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1) Escola: a portaria fica de fora ──────────────────────────────────
create or replace function public.minha_escola()
returns uuid language sql stable security definer set search_path to 'public' as $f$
  select escola_id from public.perfis where id = auth.uid() and perfil::text <> 'portaria'
$f$;

-- escola para as funções do ponto (inclui a portaria)
create or replace function public.ponto_escola()
returns uuid language sql stable security definer set search_path to 'public' as $f$
  select escola_id from public.perfis
   where id = auth.uid() and (perfil::text in ('portaria','gestor-rh','gestor','director'))
$f$;

-- ── 2) Vistas que ignoravam o RLS ───────────────────────────────────────
do $$ declare v text; begin
  foreach v in array array['v_medias_aluno','v_historico_suporte','v_suporte_activo'] loop
    if exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                where n.nspname = 'public' and c.relname = v and c.relkind = 'v') then
      execute format('alter view public.%I set (security_invoker = on)', v);
      execute format('revoke all on public.%I from anon', v);
    end if;
  end loop;
end $$;

-- ── 3) Indicadores da avaliação: não se chamam directamente ─────────────
revoke execute on function public.aval_indicadores(uuid, int) from authenticated;

-- ── 4) Gatilho do ponto ─────────────────────────────────────────────────
create or replace function public.ponto_calcular()
returns trigger language plpgsql security definer set search_path to 'public' as $f$
declare v_pp public.ponto_pessoal; v_cfg public.ponto_config; v_tol int; v_diff int;
        v_qr boolean := coalesce(current_setting('ponto.qr', true), '') = '1';
begin
  select escola_id into new.escola_id from public.staff where id = new.staff_id;
  if new.escola_id is null then raise exception 'Funcionário desconhecido.'; end if;
  if new.entrada > now() + interval '5 minutes' or new.saida > now() + interval '5 minutes' then
    raise exception 'Não se regista ponto numa hora que ainda não chegou.';
  end if;
  if tg_op = 'INSERT' then
    if new.data is null then
      new.data := (coalesce(new.entrada, new.saida, now()) at time zone 'Africa/Maputo')::date;
    end if;
    new.origem := case when v_qr then 'qr' else 'manual' end;
    new.registado_por := coalesce(auth.uid(), new.registado_por);
    new.created_at := now(); new.alterado_por := null; new.alterado_em := null;
  else
    new.alterado_por := auth.uid(); new.alterado_em := now();
    new.registado_por := old.registado_por; new.created_at := old.created_at;
    new.origem := old.origem; new.data := old.data;
  end if;
  if tg_op = 'INSERT' or new.entrada is distinct from old.entrada or new.staff_id is distinct from old.staff_id then
    select * into v_pp  from public.ponto_pessoal where staff_id = new.staff_id;
    select * into v_cfg from public.ponto_config  where escola_id = new.escola_id;
    new.hora_prevista := coalesce(v_pp.hora_entrada, v_cfg.hora_entrada, '07:30'::time);
    v_tol := coalesce(v_pp.tolerancia_min, v_cfg.tolerancia_min, 10);
    new.atraso_min := 0;
    if new.entrada is not null and not coalesce(v_pp.isento, false) then
      v_diff := floor(extract(epoch from (date_trunc('minute', (new.entrada at time zone 'Africa/Maputo'))::time
                                           - new.hora_prevista)) / 60)::int;
      if v_diff > v_tol then new.atraso_min := v_diff; end if;
    end if;
  else
    new.atraso_min := old.atraso_min; new.hora_prevista := old.hora_prevista;
  end if;
  if new.atraso_min = 0 then new.justificado := false; end if;
  return new;
end $f$;

-- ── 5) Modo Ponto ───────────────────────────────────────────────────────
create or replace function public.ponto_marcar(p_codigo text)
returns jsonb language plpgsql security definer set search_path to 'public' as $f$
declare
  v_escola uuid := ponto_escola();
  v_cod text; v_pp public.ponto_pessoal; v_s public.staff; v_r public.ponto_registos;
  v_agora timestamptz := now();
  v_hoje date := (now() at time zone 'Africa/Maputo')::date;
  v_res text;
begin
  if v_escola is null then raise exception 'Sem permissão para registar o ponto.'; end if;
  v_cod := upper(regexp_replace(coalesce(p_codigo, ''), '[^0-9A-Za-z]', '', 'g'));
  if v_cod like 'SCHP%' then v_cod := substr(v_cod, 5); end if;
  if v_cod !~ '^[0-9A-F]{32}$' then return jsonb_build_object('resultado', 'desconhecido'); end if;

  select * into v_pp from public.ponto_pessoal where codigo = v_cod and escola_id = v_escola;
  if not found then return jsonb_build_object('resultado', 'desconhecido'); end if;
  select * into v_s from public.staff where id = v_pp.staff_id;
  if not coalesce(v_s.ativo, true) then
    return jsonb_build_object('resultado', 'inactivo', 'nome', v_s.nome);
  end if;

  perform set_config('ponto.qr', '1', true);   -- o gatilho marca a origem «qr» (só nestas gravações)
  insert into public.ponto_registos (escola_id, staff_id, data, entrada)
  values (v_escola, v_s.id, v_hoje, v_agora)
  on conflict (staff_id, data) do nothing
  returning * into v_r;
  if found then
    v_res := 'entrada';
  else
    select * into v_r from public.ponto_registos where staff_id = v_s.id and data = v_hoje for update;
    if v_r.entrada is null then
      update public.ponto_registos set entrada = v_agora where id = v_r.id returning * into v_r;
      v_res := 'entrada';
    elsif v_agora - greatest(v_r.entrada, coalesce(v_r.saida, v_r.entrada)) < interval '10 minutes' then
      v_res := 'repetido';
    else
      update public.ponto_registos set saida = v_agora where id = v_r.id returning * into v_r;
      v_res := 'saida';
    end if;
  end if;
  perform set_config('ponto.qr', '', true);

  return jsonb_build_object(
    'resultado', v_res, 'nome', v_s.nome, 'cargo', v_s.cargo, 'num', v_s.num,
    'entrada', to_char(v_r.entrada at time zone 'Africa/Maputo', 'HH24:MI'),
    'saida',   to_char(v_r.saida   at time zone 'Africa/Maputo', 'HH24:MI'),
    'prevista', to_char(v_r.hora_prevista, 'HH24:MI'), 'atraso_min', v_r.atraso_min);
end $f$;

create or replace function public.ponto_quiosque()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $f$
declare v_escola uuid := ponto_escola();
begin
  if v_escola is null then raise exception 'Sem permissão.'; end if;
  return jsonb_build_object(
    'escola', (select nome from public.escolas where id = v_escola),
    'entradas_hoje', (select count(*) from public.ponto_registos
                       where escola_id = v_escola and entrada is not null
                         and data = (now() at time zone 'Africa/Maputo')::date));
end $f$;

revoke all on function public.ponto_escola(), public.ponto_marcar(text), public.ponto_quiosque(), public.ponto_calcular() from public, anon;
grant execute on function public.ponto_escola(), public.ponto_marcar(text), public.ponto_quiosque() to authenticated;
