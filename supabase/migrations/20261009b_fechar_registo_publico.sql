-- ═══════════════════════════════════════════════════════════════════════
--  Scholaris — fechar a criação de perfis e escolas por contas novas
--  2026-10-09 · app v6.246 · serve para o iQRA E para o Atlântico
--  (correr uma vez em cada SQL Editor). Idempotente.
--
--  Encontrado na auditoria de 2026-10-09 (provado no iQRA com uma sessão
--  simulada, desfeita no fim):
--   · O registo público de contas do Supabase está ligado (no iQRA nem pede
--     confirmação do email). A chave pública está na página.
--   · perfis_insert aceitava `id = auth.uid()`: uma conta acabada de criar
--     podia gravar o próprio perfil como GESTOR de qualquer escola.
--   · O trigger anti-escalada só actuava em UPDATE, não em INSERT.
--   Resultado no teste: perfil de gestor criado pela própria conta, com
--   acesso aos 343 alunos e 1 949 pagamentos.
--   · escolas_insert deixava uma conta sem escola criar uma escola.
--   · licencas: qualquer conta lia e alterava os códigos de activação.
--
--  Depois disto:
--   · perfis só são criados pela direcção da própria escola (a app, no ecrã
--     de utilizadores) ou pelas Edge Functions (chave de administração);
--   · o trigger também bloqueia INSERT de quem não é gestor/director;
--   · escolas e licenças só pela chave de administração (SQL / funções).
--  As Edge Functions criar-utilizador e gerir-utilizador usam a chave de
--  administração e NÃO são afectadas.
--
--  ⚠ Falta também DESLIGAR o registo público no painel do Supabase:
--    Authentication › Sign In / Providers › "Allow new users to sign up" = OFF
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1) Perfis: acabou a criação do próprio perfil ────────────────────────
drop policy if exists perfis_insert on public.perfis;
create policy perfis_insert on public.perfis
  for insert to authenticated
  with check (escola_id = minha_escola() and sou_gestor_dir());

-- ── 2) Trigger anti-escalada passa a cobrir INSERT ───────────────────────
create or replace function public.perfis_sem_escalada()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  -- chave de administração (Edge Functions, SQL do painel): passa
  if auth.uid() is null then return new; end if;
  -- direcção: passa (a política já a limita à própria escola)
  if public.sou_gestor_dir() then return new; end if;
  if tg_op = 'INSERT' then
    raise exception 'Só a direcção da escola pode criar contas';
  end if;
  if new.perfil            is distinct from old.perfil
     or new.escola_id      is distinct from old.escola_id
     or new.staff_id       is distinct from old.staff_id
     or new.aluno_id       is distinct from old.aluno_id
     or new.encarregado_id is distinct from old.encarregado_id then
    raise exception 'Só a direcção pode mudar o papel ou as ligações de uma conta';
  end if;
  return new;
end
$function$;

drop trigger if exists trg_perfis_sem_escalada on public.perfis;
create trigger trg_perfis_sem_escalada
  before insert or update on public.perfis
  for each row execute function public.perfis_sem_escalada();

-- ── 3) Escolas: só pela chave de administração ───────────────────────────
drop policy if exists escolas_insert on public.escolas;

-- ── 4) Licenças: sem acesso pelas contas (o assistente antigo já não se usa) ─
drop policy if exists licenca_verificar on public.licencas;
drop policy if exists licenca_usar      on public.licencas;

-- ── Verificação (opcional) ───────────────────────────────────────────────
-- select tablename, policyname, cmd, coalesce(with_check, qual) from pg_policies
--  where tablename in ('perfis','escolas','licencas') order by 1, 2;
-- select pg_get_triggerdef(oid) from pg_trigger where tgname = 'trg_perfis_sem_escalada';
