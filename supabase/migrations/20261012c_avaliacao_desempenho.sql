-- ═══════════════════════════════════════════════════════════════════════
--  Scholaris — avaliação de desempenho do pessoal (fase 3 do módulo de RH)
--  2026-10-12 · app v6.253 (iQRA) / v6.272 (Atlântico). Serve para as duas
--  escolas. Idempotente.
--
--  Modelo (decidido pela direcção da Altus a 2026-10-12):
--   · grelhas por competências, critérios de 1 a 5 com peso; uma grelha para
--     docentes e outra para não docentes; o RH pode ajustá-las;
--   · cada funcionário tem um CHEFE DIRECTO (staff.chefe_id);
--   · ciclo anual:  aberta → auto_feita → chefia_feita → validada → conhecimento
--       1. revisão a meio do ano (conversa, sem nota) registada pela chefia;
--       2. auto-avaliação pelo próprio (quem tem conta);
--       3. avaliação pela chefia, que vê a auto-avaliação;
--       4. validação pelo RH (ou direcção); abaixo de «Bom» exige plano de melhoria;
--       5. o funcionário toma conhecimento.
--   · a assiduidade (faltas injustificadas do ano) é calculada pelo servidor
--     e proposta como nível; os sumários registados aparecem como informação;
--   · a nota final (1–5, média ponderada) e a classificação são calculadas no
--     servidor: ≥4,5 Excelente · ≥3,5 Muito Bom · ≥2,5 Bom · ≥1,5 Suficiente ·
--     abaixo Insuficiente;
--   · a grelha é copiada para cada avaliação quando o ano é aberto: mudar a
--     grelha depois não altera avaliações já abertas.
--  Acesso: RH e direcção lêem e gerem tudo (tabela); o funcionário e a chefia
--  só agem pelas funções aval_* abaixo, que verificam quem é quem. O
--  funcionário só vê a avaliação da chefia depois de validada.
-- ═══════════════════════════════════════════════════════════════════════

-- ── 1) Chefe directo ─────────────────────────────────────────────────────
alter table public.staff add column if not exists chefe_id uuid references public.staff(id) on delete set null;

-- ── 2) Grelhas ───────────────────────────────────────────────────────────
create table if not exists public.aval_grelhas (
  escola_id      uuid not null references public.escolas(id) on delete cascade,
  tipo           text not null check (tipo in ('docente','nao_docente')),
  criterios      jsonb not null,
  niveis         jsonb not null,
  actualizado_em timestamptz not null default now(),
  primary key (escola_id, tipo)
);
alter table public.aval_grelhas enable row level security;
drop policy if exists aval_grelhas_ler on public.aval_grelhas;
create policy aval_grelhas_ler on public.aval_grelhas
  for select to authenticated using (escola_id = minha_escola() and not sou_familia());
drop policy if exists aval_grelhas_gerir on public.aval_grelhas;
create policy aval_grelhas_gerir on public.aval_grelhas
  for all to authenticated
  using (escola_id = minha_escola() and (sou_rh() or sou_gestor_dir()))
  with check (escola_id = minha_escola() and (sou_rh() or sou_gestor_dir()));

-- grelhas de origem (só se a escola ainda não tiver)
insert into public.aval_grelhas (escola_id, tipo, criterios, niveis)
select e.id, g.tipo, g.criterios, n.niveis
  from public.escolas e
 cross join (values
  ('nao_docente', $j$[
    {"id":"assiduidade","nome":"Assiduidade e pontualidade","descricao":"Cumpre o horário, não falta sem justificação e avisa com antecedência quando tem de se ausentar.","peso":15,"auto":"assiduidade"},
    {"id":"tarefas","nome":"Cumprimento das tarefas","descricao":"Executa as tarefas atribuídas dentro dos prazos, sem precisar de ser lembrado.","peso":20},
    {"id":"qualidade","nome":"Qualidade do trabalho","descricao":"Trabalho rigoroso e organizado, sem erros que obriguem a refazer.","peso":20},
    {"id":"equipa","nome":"Colaboração e trabalho em equipa","descricao":"Ajuda os colegas, partilha informação e contribui para um bom ambiente de trabalho.","peso":15},
    {"id":"atendimento","nome":"Relacionamento e atendimento","descricao":"Trata alunos, encarregados, colegas e visitantes com cortesia e paciência.","peso":10},
    {"id":"iniciativa","nome":"Iniciativa e responsabilidade","descricao":"Resolve problemas por si, propõe melhorias e assume as consequências do seu trabalho.","peso":10},
    {"id":"conduta","nome":"Conduta e ética profissional","descricao":"Respeita as regras da escola, a confidencialidade e o património.","peso":10}
  ]$j$::jsonb),
  ('docente', $j$[
    {"id":"assiduidade","nome":"Assiduidade e pontualidade","descricao":"Cumpre o horário das aulas, não falta sem justificação e avisa com antecedência.","peso":10,"auto":"assiduidade"},
    {"id":"planificacao","nome":"Planificação e preparação das aulas","descricao":"Prepara as aulas com antecedência, segue o plano analítico e usa materiais adequados.","peso":15},
    {"id":"programa","nome":"Cumprimento do programa e dos sumários","descricao":"Cumpre o programa da disciplina e regista os sumários das aulas dadas.","peso":15,"auto":"sumarios"},
    {"id":"resultados","nome":"Acompanhamento e resultados dos alunos","descricao":"Avalia com regularidade, lança as notas a tempo e apoia os alunos com dificuldades.","peso":15},
    {"id":"turma","nome":"Gestão da turma e disciplina","descricao":"Mantém a ordem e um bom ambiente de aprendizagem na sala de aula.","peso":10},
    {"id":"equipa","nome":"Colaboração e trabalho em equipa","descricao":"Participa nas reuniões e actividades da escola e colabora com os colegas.","peso":15},
    {"id":"relacao","nome":"Relacionamento com alunos e encarregados","descricao":"Comunica com respeito e clareza e está disponível para os encarregados.","peso":10},
    {"id":"conduta","nome":"Conduta e responsabilidade profissional","descricao":"Respeita as regras da escola, é exemplo para os alunos e guarda confidencialidade.","peso":10}
  ]$j$::jsonb)
 ) as g(tipo, criterios)
 cross join (select $j${"1":"Muito abaixo do esperado","2":"Abaixo do esperado","3":"Corresponde ao esperado","4":"Acima do esperado","5":"Excede claramente o esperado"}$j$::jsonb as niveis) n
on conflict (escola_id, tipo) do nothing;

-- ── 3) Avaliações ────────────────────────────────────────────────────────
create table if not exists public.avaliacoes_desempenho (
  id                      uuid primary key default gen_random_uuid(),
  escola_id               uuid not null references public.escolas(id) on delete cascade,
  staff_id                uuid not null references public.staff(id) on delete cascade,
  ano                     int  not null,
  tipo                    text not null check (tipo in ('docente','nao_docente')),
  grelha                  jsonb not null,
  estado                  text not null default 'aberta'
                          check (estado in ('aberta','auto_feita','chefia_feita','validada','conhecimento')),
  revisao                 jsonb,
  auto                    jsonb,
  chefia                  jsonb,
  indicadores             jsonb,
  nota_final              numeric(3,2),
  classificacao           text,
  plano_melhoria          jsonb,
  devolvida_motivo        text,
  validada_por            text,
  validada_em             timestamptz,
  conhecimento_em         timestamptz,
  conhecimento_comentario text,
  criado_em               timestamptz not null default now(),
  actualizado_em          timestamptz not null default now(),
  unique (escola_id, staff_id, ano)
);
alter table public.avaliacoes_desempenho enable row level security;
drop policy if exists avald_ler on public.avaliacoes_desempenho;
create policy avald_ler on public.avaliacoes_desempenho
  for select to authenticated using (escola_id = minha_escola() and (sou_rh() or sou_gestor_dir()));
drop policy if exists avald_criar on public.avaliacoes_desempenho;
create policy avald_criar on public.avaliacoes_desempenho
  for insert to authenticated with check (escola_id = minha_escola() and (sou_rh() or sou_gestor_dir()));
drop policy if exists avald_alterar on public.avaliacoes_desempenho;
create policy avald_alterar on public.avaliacoes_desempenho
  for update to authenticated
  using (escola_id = minha_escola() and (sou_rh() or sou_gestor_dir()))
  with check (escola_id = minha_escola() and (sou_rh() or sou_gestor_dir()));
drop policy if exists avald_apagar on public.avaliacoes_desempenho;
create policy avald_apagar on public.avaliacoes_desempenho
  for delete to authenticated using (escola_id = minha_escola() and sou_gestor_dir());

-- validada = trancada; só a direcção reabre; o próprio só passa a «conhecimento»
create or replace function public.avald_tranca()
returns trigger language plpgsql security definer set search_path to 'public' as $f$
begin
  new.actualizado_em := now();
  if auth.uid() is null then return new; end if;
  if old.estado in ('validada','conhecimento') then
    if public.sou_gestor_dir() then return new; end if;
    if old.estado = 'validada' and new.estado = 'conhecimento'
       and old.staff_id = public.meu_staff_id()
       and new.chefia is not distinct from old.chefia
       and new.nota_final is not distinct from old.nota_final then
      return new;
    end if;
    raise exception 'Avaliação validada. Só a direcção a pode reabrir.';
  end if;
  return new;
end $f$;
drop trigger if exists trg_avald_tranca on public.avaliacoes_desempenho;
create trigger trg_avald_tranca before update on public.avaliacoes_desempenho
  for each row execute function public.avald_tranca();
drop trigger if exists trg_auditoria_servidor on public.avaliacoes_desempenho;
create trigger trg_auditoria_servidor after insert or update or delete on public.avaliacoes_desempenho
  for each row execute function public.auditoria_servidor();

-- ── 4) Cálculos ──────────────────────────────────────────────────────────
create or replace function public.aval_classificacao(n numeric)
returns text language sql immutable as $f$
  select case when n is null then null
              when n >= 4.5 then 'Excelente' when n >= 3.5 then 'Muito Bom'
              when n >= 2.5 then 'Bom' when n >= 1.5 then 'Suficiente'
              else 'Insuficiente' end
$f$;

create or replace function public.aval_nota(p_grelha jsonb, p_resp jsonb)
returns numeric language sql immutable as $f$
  select round(sum((c->>'peso')::numeric * (p_resp->>(c->>'id'))::numeric)
               / nullif(sum((c->>'peso')::numeric), 0), 2)
    from jsonb_array_elements(coalesce(p_grelha->'criterios', '[]'::jsonb)) c
   where coalesce(p_resp->>(c->>'id'), '') ~ '^[1-5]$'
$f$;

create or replace function public.aval_completa(p_grelha jsonb, p_resp jsonb)
returns boolean language sql immutable as $f$
  select not exists (select 1 from jsonb_array_elements(coalesce(p_grelha->'criterios', '[]'::jsonb)) c
                      where coalesce(p_resp->>(c->>'id'), '') !~ '^[1-5]$')
$f$;

create or replace function public.aval_indicadores(p_staff uuid, p_ano int)
returns jsonb language sql stable security definer set search_path to 'public' as $f$
  with f as (
    select count(*) filter (where not coalesce(justif, false)) inj,
           count(*) filter (where coalesce(justif, false))     jus
      from public.faltas where staff_id = p_staff and extract(year from data) = p_ano
  )
  select jsonb_build_object(
    'assiduidade', jsonb_build_object('injustificadas', f.inj, 'justificadas', f.jus,
       'nivel', case when f.inj = 0 then 5 when f.inj <= 2 then 4 when f.inj <= 5 then 3
                     when f.inj <= 9 then 2 else 1 end),
    'sumarios', jsonb_build_object('aulas', (select count(*) from public.aulas_dadas
                                              where professor_id = p_staff and extract(year from data) = p_ano)))
    from f
$f$;

create or replace function public.aval_pode_chefiar(p_staff uuid)
returns boolean language sql stable security definer set search_path to 'public' as $f$
  select exists (select 1 from public.staff s
                  where s.id = p_staff and s.escola_id = public.minha_escola()
                    and p_staff is distinct from public.meu_staff_id()
                    and (s.chefe_id = public.meu_staff_id() or public.sou_rh() or public.sou_gestor_dir()))
$f$;

create or replace function public.aval_meu_nome()
returns text language sql stable security definer set search_path to 'public' as $f$
  select coalesce(nome_completo, id::text) from public.perfis where id = auth.uid()
$f$;

-- ── 5) Funções do ciclo ──────────────────────────────────────────────────
-- RH/direcção: abrir o ano (uma avaliação por funcionário activo)
create or replace function public.aval_abrir_ano(p_ano int)
returns int language plpgsql security definer set search_path to 'public' as $f$
declare n int;
begin
  if not (sou_rh() or sou_gestor_dir()) then raise exception 'Só o RH ou a direcção abrem o ano de avaliação.'; end if;
  insert into public.avaliacoes_desempenho (escola_id, staff_id, ano, tipo, grelha)
  select s.escola_id, s.id, p_ano, t.tipo, jsonb_build_object('criterios', g.criterios, 'niveis', g.niveis)
    from public.staff s
    cross join lateral (select case when s.dep = 'academico' then 'docente' else 'nao_docente' end as tipo) t
    join public.aval_grelhas g on g.escola_id = s.escola_id and g.tipo = t.tipo
   where s.escola_id = minha_escola() and coalesce(s.ativo, true)
  on conflict (escola_id, staff_id, ano) do nothing;
  get diagnostics n = row_count;
  return n;
end $f$;

-- funcionário: ver a sua avaliação (a parte da chefia só depois de validada)
create or replace function public.aval_minha(p_ano int)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $f$
declare r public.avaliacoes_desempenho; v jsonb;
begin
  select * into r from public.avaliacoes_desempenho
   where escola_id = minha_escola() and staff_id = meu_staff_id() and ano = p_ano;
  if not found then return null; end if;
  v := jsonb_build_object('id', r.id, 'ano', r.ano, 'tipo', r.tipo, 'estado', r.estado,
                          'grelha', r.grelha, 'auto', r.auto);
  if r.estado in ('validada','conhecimento') then
    v := v || jsonb_build_object('chefia', r.chefia, 'revisao', r.revisao, 'indicadores', r.indicadores,
               'nota_final', r.nota_final, 'classificacao', r.classificacao,
               'plano_melhoria', r.plano_melhoria, 'validada_em', r.validada_em,
               'conhecimento_em', r.conhecimento_em, 'conhecimento_comentario', r.conhecimento_comentario);
  end if;
  return v;
end $f$;

-- funcionário: submeter a auto-avaliação (antes da chefia)
create or replace function public.aval_submeter_auto(p_ano int, p_resp jsonb, p_comentario text)
returns text language plpgsql security definer set search_path to 'public' as $f$
declare r public.avaliacoes_desempenho;
begin
  select * into r from public.avaliacoes_desempenho
   where escola_id = minha_escola() and staff_id = meu_staff_id() and ano = p_ano;
  if not found then raise exception 'Ainda não há avaliação aberta para %.', p_ano; end if;
  if r.estado <> 'aberta' then raise exception 'A auto-avaliação já não pode ser alterada.'; end if;
  if not aval_completa(r.grelha, p_resp) then raise exception 'Responda a todos os critérios (1 a 5).'; end if;
  update public.avaliacoes_desempenho
     set auto = jsonb_build_object('respostas', p_resp, 'comentario', left(coalesce(p_comentario, ''), 2000), 'em', now()),
         estado = 'auto_feita'
   where id = r.id;
  return 'ok';
end $f$;

-- funcionário: tomar conhecimento da avaliação validada
create or replace function public.aval_tomar_conhecimento(p_ano int, p_comentario text)
returns text language plpgsql security definer set search_path to 'public' as $f$
declare r public.avaliacoes_desempenho;
begin
  select * into r from public.avaliacoes_desempenho
   where escola_id = minha_escola() and staff_id = meu_staff_id() and ano = p_ano;
  if not found or r.estado <> 'validada' then raise exception 'Não há avaliação validada para tomar conhecimento.'; end if;
  update public.avaliacoes_desempenho
     set estado = 'conhecimento', conhecimento_em = now(),
         conhecimento_comentario = left(coalesce(p_comentario, ''), 2000)
   where id = r.id;
  return 'ok';
end $f$;

-- chefia (ou RH/direcção com p_todos): lista com indicadores calculados agora
create or replace function public.aval_equipa(p_ano int, p_todos boolean default false)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $f$
declare tudo boolean := p_todos and (sou_rh() or sou_gestor_dir());
begin
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', a.id, 'staff_id', s.id, 'nome', s.nome, 'num', s.num, 'cargo', s.cargo, 'dep', s.dep,
             'chefe_id', s.chefe_id, 'chefe_nome', c.nome,
             'tipo', a.tipo, 'estado', a.estado, 'grelha', a.grelha,
             'auto', case when a.estado <> 'aberta' then a.auto end,
             'chefia', a.chefia, 'revisao', a.revisao,
             'nota_final', a.nota_final, 'classificacao', a.classificacao,
             'plano_melhoria', a.plano_melhoria, 'devolvida_motivo', a.devolvida_motivo,
             'validada_por', a.validada_por, 'validada_em', a.validada_em,
             'conhecimento_em', a.conhecimento_em, 'conhecimento_comentario', a.conhecimento_comentario,
             'indicadores', aval_indicadores(s.id, p_ano)
           ) order by s.nome), '[]'::jsonb)
      from public.avaliacoes_desempenho a
      join public.staff s on s.id = a.staff_id
      left join public.staff c on c.id = s.chefe_id
     where a.escola_id = minha_escola() and a.ano = p_ano
       and (tudo or (s.chefe_id = meu_staff_id() and s.id is distinct from meu_staff_id()))
  );
end $f$;

-- chefia: guardar (rascunho) ou submeter a avaliação
create or replace function public.aval_guardar_chefia(p_id uuid, p_resp jsonb, p_comentario text,
                                                      p_fortes text, p_melhorar text, p_submeter boolean)
returns text language plpgsql security definer set search_path to 'public' as $f$
declare r public.avaliacoes_desempenho; n numeric;
begin
  select * into r from public.avaliacoes_desempenho where id = p_id and escola_id = minha_escola();
  if not found or not aval_pode_chefiar(r.staff_id) then raise exception 'Sem permissão para avaliar este funcionário.'; end if;
  if r.estado in ('validada','conhecimento') then raise exception 'Avaliação já validada.'; end if;
  if p_submeter and not aval_completa(r.grelha, p_resp) then raise exception 'Avalie todos os critérios (1 a 5) antes de submeter.'; end if;
  n := aval_nota(r.grelha, p_resp);
  update public.avaliacoes_desempenho
     set chefia = jsonb_build_object('respostas', coalesce(p_resp, '{}'::jsonb),
                    'comentario', left(coalesce(p_comentario, ''), 3000),
                    'pontos_fortes', left(coalesce(p_fortes, ''), 2000),
                    'a_melhorar', left(coalesce(p_melhorar, ''), 2000),
                    'por', aval_meu_nome(), 'em', now(), 'submetida', p_submeter),
         indicadores = aval_indicadores(r.staff_id, r.ano),
         estado = case when p_submeter then 'chefia_feita' else r.estado end,
         nota_final = case when p_submeter then n else r.nota_final end,
         classificacao = case when p_submeter then aval_classificacao(n) else r.classificacao end,
         devolvida_motivo = case when p_submeter then null else r.devolvida_motivo end
   where id = r.id;
  return 'ok';
end $f$;

-- chefia: revisão a meio do ano (conversa, sem nota)
create or replace function public.aval_revisao(p_id uuid, p_data date, p_notas text)
returns text language plpgsql security definer set search_path to 'public' as $f$
declare r public.avaliacoes_desempenho;
begin
  select * into r from public.avaliacoes_desempenho where id = p_id and escola_id = minha_escola();
  if not found or not aval_pode_chefiar(r.staff_id) then raise exception 'Sem permissão.'; end if;
  if r.estado in ('validada','conhecimento') then raise exception 'Avaliação já validada.'; end if;
  update public.avaliacoes_desempenho
     set revisao = jsonb_build_object('data', p_data, 'notas', left(coalesce(p_notas, ''), 3000),
                                      'por', aval_meu_nome(), 'em', now())
   where id = r.id;
  return 'ok';
end $f$;

-- RH/direcção: validar (abaixo de «Bom» exige plano de melhoria)
create or replace function public.aval_validar(p_id uuid, p_plano jsonb)
returns text language plpgsql security definer set search_path to 'public' as $f$
declare r public.avaliacoes_desempenho; n numeric;
begin
  if not (sou_rh() or sou_gestor_dir()) then raise exception 'Só o RH ou a direcção validam.'; end if;
  select * into r from public.avaliacoes_desempenho where id = p_id and escola_id = minha_escola();
  if not found then raise exception 'Avaliação não encontrada.'; end if;
  if r.staff_id = meu_staff_id() and not sou_gestor_dir() then raise exception 'Não pode validar a sua própria avaliação.'; end if;
  if r.estado <> 'chefia_feita' then raise exception 'Só se valida depois de a chefia submeter a avaliação.'; end if;
  n := aval_nota(r.grelha, r.chefia->'respostas');
  if n < 2.5 and coalesce(trim(p_plano->>'objectivos'), '') = '' then
    raise exception 'Com classificação abaixo de «Bom» é obrigatório um plano de melhoria.';
  end if;
  update public.avaliacoes_desempenho
     set estado = 'validada', nota_final = n, classificacao = aval_classificacao(n),
         plano_melhoria = case when coalesce(trim(p_plano->>'objectivos'), '') = '' then null else p_plano end,
         validada_por = aval_meu_nome(), validada_em = now()
   where id = r.id;
  return 'ok';
end $f$;

-- RH/direcção: devolver à chefia
create or replace function public.aval_devolver(p_id uuid, p_motivo text)
returns text language plpgsql security definer set search_path to 'public' as $f$
declare r public.avaliacoes_desempenho;
begin
  if not (sou_rh() or sou_gestor_dir()) then raise exception 'Só o RH ou a direcção devolvem.'; end if;
  select * into r from public.avaliacoes_desempenho where id = p_id and escola_id = minha_escola();
  if not found or r.estado <> 'chefia_feita' then raise exception 'Só se devolve uma avaliação submetida pela chefia.'; end if;
  update public.avaliacoes_desempenho
     set estado = case when r.auto is not null then 'auto_feita' else 'aberta' end,
         chefia = coalesce(r.chefia, '{}'::jsonb) || '{"submetida":false}'::jsonb,
         devolvida_motivo = left(coalesce(p_motivo, ''), 1000)
   where id = r.id;
  return 'ok';
end $f$;

-- direcção: reabrir uma avaliação validada
create or replace function public.aval_reabrir(p_id uuid)
returns text language plpgsql security definer set search_path to 'public' as $f$
begin
  if not sou_gestor_dir() then raise exception 'Só a direcção reabre avaliações validadas.'; end if;
  update public.avaliacoes_desempenho
     set estado = 'chefia_feita', validada_por = null, validada_em = null,
         conhecimento_em = null, conhecimento_comentario = null
   where id = p_id and escola_id = minha_escola() and estado in ('validada','conhecimento');
  return 'ok';
end $f$;

revoke all on function public.aval_abrir_ano(int), public.aval_minha(int), public.aval_submeter_auto(int, jsonb, text),
  public.aval_tomar_conhecimento(int, text), public.aval_equipa(int, boolean),
  public.aval_guardar_chefia(uuid, jsonb, text, text, text, boolean), public.aval_revisao(uuid, date, text),
  public.aval_validar(uuid, jsonb), public.aval_devolver(uuid, text), public.aval_reabrir(uuid),
  public.aval_indicadores(uuid, int), public.aval_pode_chefiar(uuid), public.aval_meu_nome() from public, anon;
grant execute on function public.aval_abrir_ano(int), public.aval_minha(int), public.aval_submeter_auto(int, jsonb, text),
  public.aval_tomar_conhecimento(int, text), public.aval_equipa(int, boolean),
  public.aval_guardar_chefia(uuid, jsonb, text, text, text, boolean), public.aval_revisao(uuid, date, text),
  public.aval_validar(uuid, jsonb), public.aval_devolver(uuid, text), public.aval_reabrir(uuid)
  to authenticated;
