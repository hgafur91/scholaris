-- ═══════════════════════════════════════════════════════════════════════
--  Scholaris — «O Meu Ponto»: cada funcionário vê o próprio registo
--  2026-10-14 · iQRA v6.262 / Atlântico v6.281. Idempotente.
--  Devolve só os dados de quem pergunta (meu_staff_id()): horário que lhe
--  aplica, entradas/saídas/atrasos do ano e faltas do pessoal do ano.
--  Não abre as tabelas: a configuração e as faltas continuam fechadas.
-- ═══════════════════════════════════════════════════════════════════════
create or replace function public.ponto_meu(p_ano int)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $f$
declare v_staff uuid := meu_staff_id(); v_escola uuid := minha_escola();
        v_pp public.ponto_pessoal; v_cfg public.ponto_config;
begin
  if v_staff is null or v_escola is null then return null; end if;
  if not exists (select 1 from public.staff where id = v_staff and escola_id = v_escola) then return null; end if;
  select * into v_pp  from public.ponto_pessoal where staff_id = v_staff;
  select * into v_cfg from public.ponto_config  where escola_id = v_escola;
  return jsonb_build_object(
    'nome', (select nome from public.staff where id = v_staff),
    'horario', jsonb_build_object(
       'hora_entrada', to_char(coalesce(v_pp.hora_entrada, v_cfg.hora_entrada, '07:30'::time), 'HH24:MI'),
       'tolerancia_min', coalesce(v_pp.tolerancia_min, v_cfg.tolerancia_min, 10),
       'atrasos_por_falta', coalesce(v_cfg.atrasos_por_falta, 3),
       'isento', coalesce(v_pp.isento, false),
       'tem_cartao', v_pp.codigo is not null),
    'registos', coalesce((select jsonb_agg(jsonb_build_object(
         'data', r.data, 'entrada', r.entrada, 'saida', r.saida, 'prevista', to_char(r.hora_prevista, 'HH24:MI'),
         'atraso_min', r.atraso_min, 'justificado', r.justificado, 'motivo', r.motivo, 'origem', r.origem) order by r.data desc)
       from public.ponto_registos r where r.staff_id = v_staff and extract(year from r.data) = p_ano), '[]'::jsonb),
    'faltas', coalesce((select jsonb_agg(jsonb_build_object('data', f.data, 'justif', coalesce(f.justif, false), 'motivo', f.motivo) order by f.data desc)
       from public.faltas f where f.staff_id = v_staff and extract(year from f.data) = p_ano), '[]'::jsonb));
end $f$;

revoke all on function public.ponto_meu(int) from public, anon;
grant execute on function public.ponto_meu(int) to authenticated;
