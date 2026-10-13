-- ═══════════════════════════════════════════════════════════════════════
--  Scholaris — o Gestor de RH grava os subsídios e descontos fixos
--  2026-10-13 · app v6.257 (iQRA) / v6.276 (Atlântico). Idempotente.
--
--  Os subsídios e descontos fixos por trabalhador vivem em escolas.config
--  (subsidiosFixos / descontosFixos). Essa linha só a direcção e a secretaria
--  alteram (escolas_update), por isso o RH editava-os no ecrã mas nada ficava
--  gravado. Esta função deixa o RH (e a direcção) gravar SÓ estas duas chaves
--  da configuração — o resto da configuração da escola continua fechado.
-- ═══════════════════════════════════════════════════════════════════════
create or replace function public.rh_gravar_fixos(p_subs jsonb, p_descs jsonb)
returns text language plpgsql security definer set search_path to 'public' as $f$
begin
  if not (sou_rh() or sou_gestor_dir()) then raise exception 'Sem permissão.'; end if;
  if jsonb_typeof(coalesce(p_subs, '{}'::jsonb)) <> 'object' or jsonb_typeof(coalesce(p_descs, '{}'::jsonb)) <> 'object' then
    raise exception 'Formato inválido.';
  end if;
  update public.escolas
     set config = coalesce(config, '{}'::jsonb)
                  || jsonb_build_object('subsidiosFixos', coalesce(p_subs, '{}'::jsonb),
                                        'descontosFixos', coalesce(p_descs, '{}'::jsonb))
   where id = minha_escola();
  return 'ok';
end $f$;
revoke all on function public.rh_gravar_fixos(jsonb, jsonb) from public, anon;
grant execute on function public.rh_gravar_fixos(jsonb, jsonb) to authenticated;
