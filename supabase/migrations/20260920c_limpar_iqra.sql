-- Scholaris (Colégio iQRA) — v6.223, parte 2 de 2: limpar o que já foi copiado.
--
-- Corre depois de `20260920b_financas_iqra.sql` e depois de a aplicação já ler e
-- gravar nas tabelas novas. Cada bloco confere primeiro e só depois limpa.

-- 1) Tirar as folhas de salários e as contas bancárias do `config`
--    (só na escola cuja cópia bate certo, campo a campo)
update public.escolas e
   set config = (e.config - 'folhas' - 'contasBanco')
  from public.escola_financas f
 where f.escola_id = e.id
   and f.folhas       = coalesce(e.config->'folhas', '{}'::jsonb)
   and f.contas_banco = coalesce(e.config->'contasBanco', '{}'::jsonb);

-- 2) Largar da tabela `staff` as colunas confidenciais.
--    Tudo num só bloco: se faltar uma ficha por copiar, levanta erro e não
--    se apaga coluna nenhuma.
do $t$
declare n integer;
begin
  select count(*) into n
    from public.staff s
    left join public.staff_confidencial c on c.staff_id = s.id
   where c.staff_id is null
      or c.salario        is distinct from s.salario
      or c.subsidio_cargo is distinct from s.subsidio_cargo
      or c.iban           is distinct from s.iban
      or c.banco          is distinct from s.banco
      or c.bi             is distinct from s.bi
      or c.niss           is distinct from s.niss
      or c.nuit           is distinct from s.nuit;

  if n > 0 then
    raise exception 'Há % ficha(s) por copiar para staff_confidencial — não se apagou nada', n;
  end if;

  execute 'alter table public.staff
             drop column if exists salario,
             drop column if exists subsidio_cargo,
             drop column if exists iban,
             drop column if exists banco,
             drop column if exists bi,
             drop column if exists niss,
             drop column if exists nuit';
end
$t$;

notify pgrst, 'reload schema';
