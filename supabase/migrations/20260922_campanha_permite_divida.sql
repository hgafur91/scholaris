-- Scholaris — a campanha pode permitir renovar quem tem dívida.
--
-- Hoje um aluno com propinas em atraso só renova com autorização do director ou do
-- gestor, aluno a aluno. A campanha passa a poder abrir essa porta durante o período,
-- para a secretaria renovar sem pedir autorização caso a caso. A dívida mantém-se:
-- o que a campanha dispensa é a autorização, não o pagamento.

begin;

alter table public.campanhas_isencao add column if not exists permite_divida boolean not null default false;

comment on column public.campanhas_isencao.permite_divida is
  'Durante a campanha, quem tem dívida pode renovar sem autorização individual da direcção.';

-- uma campanha tem de fazer alguma coisa: isentar uma taxa ou permitir a renovação com dívida
alter table public.campanhas_isencao drop constraint if exists campanha_isenta;
alter table public.campanhas_isencao add constraint campanha_isenta
  check (isenta_matricula or isenta_renovacao or permite_divida);

-- depois de criada, a campanha continua a não se poder alterar (só encerrar)
create or replace function public.campanha_isencao_valida()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
declare hoje date := (now() at time zone 'Africa/Maputo')::date;
begin
  if tg_op = 'INSERT' and new.inicio < hoje then
    raise exception 'A campanha não pode começar antes de hoje';
  end if;
  if tg_op = 'UPDATE' then
    if new.nome is distinct from old.nome
       or new.isenta_matricula is distinct from old.isenta_matricula
       or new.isenta_renovacao is distinct from old.isenta_renovacao
       or new.permite_divida   is distinct from old.permite_divida
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

commit;

notify pgrst, 'reload schema';
