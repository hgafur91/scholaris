-- Scholaris (Colégio iQRA) — v6.222: as mesmas correcções de segurança feitas no
-- Atlântico, adaptadas ao que existe aqui.
--
-- Passo 1: acabar com as políticas de desenvolvimento abertas a toda a gente,
--          mesmo a quem não tem sessão iniciada.
-- Passo 2: separar o pessoal administrativo de quem lecciona no acesso ao
--          dinheiro, aos salários e à auditoria.
-- Passo 3: ficheiros, conversas e comunicados.
--
-- Diferenças em relação ao Atlântico: aqui não existe a tabela `documentos_aluno`
-- (o dossier de documentos não foi portado) e existem políticas RESTRICTIVE
-- `familia_*`, que se mantêm tal como estão — apertam ainda mais, não abrem.

begin;

-- ════════════════════════════════════════════════════════════════════════
-- 0) Funções de apoio
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.sou_admin()
returns boolean language sql stable security definer set search_path to 'public' as $fn$
  select exists(
    select 1 from public.perfis
    where id = auth.uid()
      and perfil in ('gestor','director','dir-pedagogico','dir-ciclo','secretario')
  )
$fn$;

create or replace function public.meu_staff_id()
returns uuid language sql stable security definer set search_path to 'public' as $fn$
  select staff_id from public.perfis where id = auth.uid()
$fn$;

create or replace function public.meu_nome()
returns text language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(nome_completo, nome) from public.perfis where id = auth.uid()
$fn$;

grant execute on function public.sou_admin()    to anon, authenticated;
grant execute on function public.meu_staff_id() to anon, authenticated;
grant execute on function public.meu_nome()     to authenticated;

-- ════════════════════════════════════════════════════════════════════════
-- 1) PERFIS — qualquer pessoa mudava o perfil de qualquer conta
-- ════════════════════════════════════════════════════════════════════════

drop policy if exists perfis_update_dev   on public.perfis;
drop policy if exists perfis_insert_dev   on public.perfis;
drop policy if exists setup_insert_perfil on public.perfis;
drop policy if exists perfis_update       on public.perfis;
drop policy if exists perfis_insert       on public.perfis;

create policy perfis_update on public.perfis for update to authenticated
  using      ( id = auth.uid() or (escola_id = public.minha_escola() and public.sou_gestor_dir()) )
  with check ( id = auth.uid() or (escola_id = public.minha_escola() and public.sou_gestor_dir()) );

create policy perfis_insert on public.perfis for insert to authenticated
  with check ( id = auth.uid() or (escola_id = public.minha_escola() and public.sou_gestor_dir()) );

create or replace function public.perfis_sem_escalada()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
begin
  if auth.uid() is null then return new; end if;
  if public.sou_gestor_dir() then return new; end if;
  if new.perfil            is distinct from old.perfil
     or new.escola_id      is distinct from old.escola_id
     or new.staff_id       is distinct from old.staff_id
     or new.aluno_id       is distinct from old.aluno_id
     or new.encarregado_id is distinct from old.encarregado_id then
    raise exception 'Só a direcção pode mudar o papel ou as ligações de uma conta';
  end if;
  return new;
end
$fn$;

drop trigger if exists trg_perfis_sem_escalada on public.perfis;
create trigger trg_perfis_sem_escalada
  before update on public.perfis
  for each row execute function public.perfis_sem_escalada();

-- ════════════════════════════════════════════════════════════════════════
-- 2) ESCOLAS — a linha da escola era legível e alterável sem sessão
-- ════════════════════════════════════════════════════════════════════════

drop policy if exists ler_escolas         on public.escolas;
drop policy if exists actualizar_escolas  on public.escolas;
drop policy if exists setup_insert_escola on public.escolas;
drop policy if exists escolas_select      on public.escolas;
drop policy if exists escolas_update      on public.escolas;
drop policy if exists escolas_insert      on public.escolas;

create policy escolas_select on public.escolas for select to authenticated
  using ( id = public.minha_escola() or public.meu_perfil() = 'admin_sistema' );

create policy escolas_update on public.escolas for update to authenticated
  using      ( id = public.minha_escola() and public.sou_admin() )
  with check ( id = public.minha_escola() and public.sou_admin() );

create policy escolas_insert on public.escolas for insert to authenticated
  with check ( public.minha_escola() is null or public.meu_perfil() = 'admin_sistema' );

-- O ecrã de entrada precisa do nome e do logótipo antes de haver sessão.
create or replace view public.escola_marca as
  select id,
         nome,
         settings->>'logo'       as logo,
         settings->>'logoEscuro' as logo_escuro,
         settings->>'logoIcone'  as logo_icone,
         settings->>'subNome'    as sub_nome
    from public.escolas;

alter view public.escola_marca set (security_invoker = off);
revoke all on public.escola_marca from anon, authenticated;
grant select on public.escola_marca to anon, authenticated;

-- ════════════════════════════════════════════════════════════════════════
-- 3) ATRIBUIÇÕES, ENCARREGADOS, STAFF, LICENÇAS
-- ════════════════════════════════════════════════════════════════════════

drop policy if exists atrib_all           on public.atribuicoes;
drop policy if exists ler_atribuicoes     on public.atribuicoes;
drop policy if exists inserir_atribuicoes on public.atribuicoes;
drop policy if exists apagar_atribuicoes  on public.atribuicoes;

create policy atrib_select on public.atribuicoes for select to authenticated
  using ( escola_id = public.minha_escola() );

create policy atrib_write on public.atribuicoes for all to authenticated
  using      ( escola_id = public.minha_escola() and public.sou_admin() )
  with check ( escola_id = public.minha_escola() and public.sou_admin() );

drop policy if exists enc_select on public.encarregados;
drop policy if exists enc_insert on public.encarregados;
drop policy if exists enc_update on public.encarregados;
drop policy if exists enc_delete on public.encarregados;

create policy enc_staff on public.encarregados for all to authenticated
  using      ( escola_id = public.minha_escola() and public.sou_admin() )
  with check ( escola_id = public.minha_escola() and public.sou_admin() );

create policy enc_ve_se_proprio on public.encarregados for select to authenticated
  using ( id = (select encarregado_id from public.perfis where id = auth.uid()) );

drop policy if exists staff_insert on public.staff;
create policy staff_insert on public.staff for insert to authenticated
  with check ( escola_id = public.minha_escola() and public.sou_gestor_dir() );

drop policy if exists "verificar licenca" on public.licencas;
drop policy if exists "usar licenca"      on public.licencas;
create policy licenca_verificar on public.licencas for select to authenticated using ( true );
create policy licenca_usar      on public.licencas for update to authenticated using ( true ) with check ( true );

-- ════════════════════════════════════════════════════════════════════════
-- 4) O dinheiro, os salários e a auditoria saem do alcance de quem lecciona
-- ════════════════════════════════════════════════════════════════════════

drop policy if exists pagamentos_select on public.pagamentos;
drop policy if exists pagamentos_insert on public.pagamentos;
drop policy if exists pagamentos_update on public.pagamentos;
create policy pagamentos_select on public.pagamentos for select to authenticated
  using ( escola_id = public.minha_escola() and public.sou_admin() );
create policy pagamentos_insert on public.pagamentos for insert to authenticated
  with check ( escola_id = public.minha_escola() and public.sou_admin() );
create policy pagamentos_update on public.pagamentos for update to authenticated
  using      ( escola_id = public.minha_escola() and public.sou_admin() )
  with check ( escola_id = public.minha_escola() and public.sou_admin() );

drop policy if exists despesas_select on public.despesas;
drop policy if exists despesas_insert on public.despesas;
drop policy if exists despesas_update on public.despesas;
create policy despesas_select on public.despesas for select to authenticated
  using ( escola_id = (public.minha_escola())::text and public.sou_admin() );
create policy despesas_insert on public.despesas for insert to authenticated
  with check ( escola_id = (public.minha_escola())::text and public.sou_admin() );
create policy despesas_update on public.despesas for update to authenticated
  using      ( escola_id = (public.minha_escola())::text and public.sou_admin() )
  with check ( escola_id = (public.minha_escola())::text and public.sou_admin() );

drop policy if exists staff_select on public.staff;
create policy staff_select on public.staff for select to authenticated
  using ( escola_id = public.minha_escola()
          and ( public.sou_admin() or id = public.meu_staff_id() ) );

drop policy if exists auditoria_select on public.auditoria;
create policy auditoria_select on public.auditoria for select to authenticated
  using ( escola_id = public.minha_escola() and public.sou_admin() );

drop policy if exists avalstaff_select on public.avaliacoes_staff;
create policy avalstaff_select on public.avaliacoes_staff for select to authenticated
  using ( escola_id = public.minha_escola()
          and ( public.sou_admin() or staff_id = public.meu_staff_id() ) );

drop policy if exists ferias_select on public.staff_ferias;
create policy ferias_select on public.staff_ferias for select to authenticated
  using ( escola_id = public.minha_escola()
          and ( public.sou_admin() or staff_id = public.meu_staff_id() ) );

-- ════════════════════════════════════════════════════════════════════════
-- 5) Ficheiros, conversas, mensagens e comunicados
-- ════════════════════════════════════════════════════════════════════════

drop policy if exists ficheiros_read   on storage.objects;
drop policy if exists ficheiros_insert on storage.objects;
drop policy if exists ficheiros_delete on storage.objects;

create policy ficheiros_read on storage.objects for select to authenticated
using (
  bucket_id = 'escola-ficheiros'
  and (storage.foldername(name))[1] = (public.minha_escola())::text
  and (
    (storage.foldername(name))[2] is distinct from 'documentos'
    or public.sou_admin()
    or (storage.foldername(name))[3] in (select public.meus_educandos_nums())
    or (storage.foldername(name))[3] = (
         select a.numero_aluno from public.alunos a
           join public.perfis p on p.aluno_id = a.id
          where p.id = auth.uid()
       )
  )
);

create policy ficheiros_insert on storage.objects for insert to authenticated
with check (
  bucket_id = 'escola-ficheiros'
  and (storage.foldername(name))[1] = (public.minha_escola())::text
  and ( public.sou_staff() or (storage.foldername(name))[2] = 'entregas' )
);

create policy ficheiros_delete on storage.objects for delete to authenticated
using (
  bucket_id = 'escola-ficheiros'
  and (storage.foldername(name))[1] = (public.minha_escola())::text
  and ( case when (storage.foldername(name))[2] = 'documentos'
             then public.sou_admin() else public.sou_staff() end )
);

drop policy if exists conv_select on public.conversas;
drop policy if exists conv_write  on public.conversas;

create policy conv_select on public.conversas for select to authenticated
  using ( escola_id = public.minha_escola() and participantes ? public.meu_nome() );

create policy conv_insert on public.conversas for insert to authenticated
  with check ( escola_id = public.minha_escola() and participantes ? public.meu_nome() );

create policy conv_update on public.conversas for update to authenticated
  using      ( escola_id = public.minha_escola() and participantes ? public.meu_nome() )
  with check ( escola_id = public.minha_escola() and participantes ? public.meu_nome() );

drop policy if exists msg_select on public.mensagens;
drop policy if exists msg_write  on public.mensagens;

create policy msg_select on public.mensagens for select to authenticated
  using ( escola_id = public.minha_escola()
          and conversa_id in (select c.id from public.conversas c
                               where c.participantes ? public.meu_nome()) );

create policy msg_insert on public.mensagens for insert to authenticated
  with check ( escola_id = public.minha_escola()
               and de = public.meu_nome()
               and conversa_id in (select c.id from public.conversas c
                                    where c.participantes ? public.meu_nome()) );

drop policy if exists comunicados_tenant on public.comunicados;

create policy comunicados_select on public.comunicados for select to authenticated
  using ( escola_id = public.minha_escola() );

create policy comunicados_write on public.comunicados for all to authenticated
  using      ( escola_id = public.minha_escola() and public.sou_staff() )
  with check ( escola_id = public.minha_escola() and public.sou_staff() );

commit;

notify pgrst, 'reload schema';
