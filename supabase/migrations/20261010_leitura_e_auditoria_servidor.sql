-- ═══════════════════════════════════════════════════════════════════════
--  Scholaris — leitura das famílias e do professor + auditoria no servidor
--  2026-10-10 · app v6.248 · correr no SQL Editor do Supabase, de uma vez.
--  Idempotente: pode correr-se duas vezes.
--
--  Análise OWASP de 2026-10-09:
--   A01  · alunos e encarregados liam os sumários de TODAS as turmas
--          (aulas_dadas, 951) e todas as atribuições professor↔turma;
--        · o professor lia todas as facturas (valores, multas, estado).
--   A09  · a auditoria só era escrita pelo browser (podia ser saltada ou
--          inventada); não havia registo no servidor de pagamentos,
--          facturas, contas, alunos, matrículas e finanças.
--
--  Depois disto:
--   · aulas_dadas / atribuicoes: aluno e encarregado só vêem as turmas onde
--     o aluno (ou os educandos) tem matrícula activa; o pessoal não muda;
--   · facturas: o professor deixa de ler (aluno/encarregado continuam a ver
--     as suas; direcção e secretaria tudo);
--   · gatilhos no servidor gravam em `auditoria` (session_id = 'servidor')
--     cada criação, alteração e remoção em pagamentos, facturas, perfis,
--     alunos, matriculas, escola_financas e staff_confidencial — com quem
--     fez, o papel e os campos alterados (antes → depois). Não dá para
--     saltar pelo browser;
--   · o browser deixa de poder gravar linhas marcadas como 'servidor'.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1) Turmas da família (aluno: a sua; encarregado: as dos educandos) ───
create or replace function public.familia_turmas()
returns setof uuid
language sql
stable
security definer
set search_path to 'public'
as $f$
  select m.turma_id
    from public.matriculas m
   where m.estado::text = 'activa'
     and m.turma_id is not null
     and (   m.aluno_id = (select p.aluno_id from public.perfis p where p.id = auth.uid())
          or m.aluno_id in (select public.meus_educandos()) )
$f$;

-- aulas_dadas.turma_id guarda o NOME da turma (ex.: '1A'), não o uuid
drop policy if exists familia_so_sua_turma on public.aulas_dadas;
create policy familia_so_sua_turma on public.aulas_dadas
  as restrictive for select to authenticated
  using (not sou_familia()
         or turma_id in (select t.nome from public.turmas t
                          where t.id in (select public.familia_turmas())));

drop policy if exists familia_so_sua_turma on public.atribuicoes;
create policy familia_so_sua_turma on public.atribuicoes
  as restrictive for select to authenticated
  using (not sou_familia() or turma_id in (select public.familia_turmas()));

-- ── 2) Facturas: o professor não lê ──────────────────────────────────────
drop policy if exists professor_sem_facturas on public.facturas;
create policy professor_sem_facturas on public.facturas
  as restrictive for select to authenticated
  using (meu_perfil() is distinct from 'professor');

-- ── 3) Auditoria no servidor ─────────────────────────────────────────────
create or replace function public.auditoria_servidor()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $f$
declare
  novo   jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  velho  jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  linha  jsonb := coalesce(novo, velho);
  quem   text;
  papel  text;
  det    text := '';
  k      text;
  escola uuid;
  v_ant  numeric;
  v_dep  numeric;
begin
  -- campos alterados (ignora carimbos de data)
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(novo) loop
      continue when k in ('updated_at','created_at','criado_em','actualizado_em');
      if (novo -> k) is distinct from (velho -> k) then
        det := det || k || ': ' || left(coalesce(velho ->> k, '∅'), 60)
                   || ' → ' || left(coalesce(novo ->> k, '∅'), 60) || '; ';
      end if;
    end loop;
    if det = '' then return null; end if;   -- nada mudou de facto
  elsif tg_op = 'INSERT' then
    det := 'criado';
  else
    det := 'apagado';
  end if;

  if auth.uid() is null then
    quem := 'sistema (chave de administração)';
  else
    select coalesce(p.nome_completo, p.id::text), p.perfil::text
      into quem, papel
      from public.perfis p where p.id = auth.uid();
    quem := coalesce(quem, auth.uid()::text);
  end if;

  if (linha ->> 'escola_id') ~* '^[0-9a-f-]{36}$' then
    escola := (linha ->> 'escola_id')::uuid;
  end if;
  if (velho ->> 'valor_total') ~ '^-?[0-9]+(\.[0-9]+)?$' then v_ant := (velho ->> 'valor_total')::numeric; end if;
  if (novo  ->> 'valor_total') ~ '^-?[0-9]+(\.[0-9]+)?$' then v_dep := (novo  ->> 'valor_total')::numeric; end if;

  insert into public.auditoria
    (escola_id, session_id, utilizador, role, accao, entidade, detalhe, valor_antes, valor_depois)
  values
    (escola, 'servidor', quem, coalesce(papel, 'sistema'),
     'SERVIDOR_' || upper(tg_table_name) || '_' || tg_op,
     tg_table_name || ' ' || coalesce(linha ->> 'numero', linha ->> 'aluno_num',
                                      linha ->> 'nome_completo', linha ->> 'id', ''),
     left(det, 900), v_ant, v_dep);
  return null;
exception when others then
  -- a auditoria nunca deve impedir a operação; fica o aviso no registo do Postgres
  raise warning 'auditoria_servidor (%): %', tg_table_name, sqlerrm;
  return null;
end
$f$;

do $d$
declare t text;
begin
  foreach t in array array['pagamentos','facturas','perfis','alunos','matriculas',
                           'escola_financas','staff_confidencial'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists trg_auditoria_servidor on public.%I', t);
      execute format('create trigger trg_auditoria_servidor after insert or update or delete on public.%I
                        for each row execute function public.auditoria_servidor()', t);
    end if;
  end loop;
end
$d$;

-- ── 4) O browser não pode fingir linhas do servidor ──────────────────────
drop policy if exists auditoria_sem_servidor on public.auditoria;
create policy auditoria_sem_servidor on public.auditoria
  as restrictive for insert to authenticated
  with check (session_id is distinct from 'servidor');

-- ── Verificação (opcional) ───────────────────────────────────────────────
-- select tgrelid::regclass, tgname from pg_trigger where tgname = 'trg_auditoria_servidor';
-- select accao, utilizador, entidade, detalhe, criado_em from auditoria
--  where session_id = 'servidor' order by criado_em desc limit 20;
