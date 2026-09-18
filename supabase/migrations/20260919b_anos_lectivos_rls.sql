-- Scholaris (iQRA) — v6.214: ler os anos lectivos da própria escola.
-- A regra antiga só aceitava a escola vinda do token (auth_escola_id), que nem todas as
-- contas trazem; as restantes tabelas usam minha_escola(). Aqui aceitam-se as duas.

drop policy if exists anos_select on public.anos_lectivos;
create policy anos_select on public.anos_lectivos
  for select using (
    escola_id = public.minha_escola()
    or escola_id = public.auth_escola_id()
    or public.suporte_activo_para(escola_id)
  );

notify pgrst, 'reload schema';
