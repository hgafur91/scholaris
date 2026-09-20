-- Scholaris — a auditoria passa a ser só do gestor e do director.
--
-- Estava em `sou_admin()`, que inclui o secretário, o director pedagógico e o
-- coordenador de ciclo. Na interface já lhes estava vedada; agora também por
-- baixo dela. O registo continua aberto a todo o pessoal (`auditoria_insert`),
-- para que as acções de toda a gente fiquem na história.

begin;

drop policy if exists auditoria_select on public.auditoria;

create policy auditoria_select on public.auditoria for select to authenticated
  using ( escola_id = public.minha_escola() and public.sou_gestor_dir() );

commit;

notify pgrst, 'reload schema';
