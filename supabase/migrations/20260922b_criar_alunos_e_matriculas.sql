-- Scholaris — criar alunos e matrículas passa a ser só do pessoal administrativo.
--
-- As duas regras estavam abertas a qualquer utilizador com sessão: no Atlântico isso
-- incluía alunos e encarregados; no iQRA, todo o pessoal, professores incluídos.
-- Passam a ser da direcção e da secretaria — `sou_admin()` —, que é quem regista
-- alunos novos e renovações nos ecrãs.

begin;

drop policy if exists alunos_insert on public.alunos;
create policy alunos_insert on public.alunos for insert to authenticated
  with check ( escola_id = public.minha_escola() and public.sou_admin() );

drop policy if exists mat_insert on public.matriculas;
create policy mat_insert on public.matriculas for insert to authenticated
  with check ( escola_id = public.minha_escola() and public.sou_admin() );

commit;

notify pgrst, 'reload schema';
