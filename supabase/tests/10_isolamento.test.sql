-- Isolamento entre empresas e matriz de papéis.
-- Cada comando roda como um usuário (role authenticated + claim "sub", como o PostgREST faz)
-- dentro de uma subtransação desfeita ao final; o resultado vira texto comparável:
--   'linhas=N'  consulta (SELECT/WITH) → count retornado
--   'ok=N'      DML executado → linhas afetadas
--   'erro=XXXXX' SQLSTATE (42501 = privilégio/RLS; 23503 = FK; KJ001/KJ002 = regras próprias)
begin;
create extension if not exists pgtap with schema extensions;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create temp table fx (chave text primary key, id uuid not null) on commit drop;

create function pg_temp.fx(k text) returns uuid language sql stable as $$
  select id from fx where chave = k
$$;

do $$
declare
  u text;
  e text;
  emp uuid;
  estab uuid;
  trab uuid;
  pgr uuid;
  nc uuid;
  acao uuid;
  trei uuid;
begin
  foreach u in array array[
    'a_admin', 'a_tec', 'a_med', 'a_cli', 'b_admin', 'b_tec', 'b_med', 'b_cli',
    'duplo', 'duplo_tec', 'inativo', 'c_tec', 'sem_vinculo'
  ] loop
    insert into fx values ('u_' || u, gen_random_uuid());
    insert into auth.users (id, email) values (pg_temp.fx('u_' || u), u || '@teste.kaiju.invalid');
  end loop;

  foreach e in array array['A', 'B'] loop
    insert into public.empresas (razao_social, cnpj, grau_risco)
    values ('Empresa ' || e, repeat(case e when 'A' then '1' else '2' end, 14), 3)
    returning id into emp;
    insert into public.estabelecimentos (empresa_id, tipo, nome)
    values (emp, 'obra', 'Obra ' || e) returning id into estab;
    insert into public.trabalhadores (empresa_id, estabelecimento_id, nome, cpf)
    values (emp, estab, 'Trabalhador ' || e, repeat(case e when 'A' then '1' else '2' end, 11))
    returning id into trab;
    insert into public.pgrs (empresa_id, estabelecimento_id, versao, data_elaboracao)
    values (emp, estab, '1', current_date) returning id into pgr;
    insert into public.nao_conformidades (empresa_id, origem, descricao, norma_ref, item_ref)
    values (emp, 'auditoria_nr', 'NC ' || e, 'NR-35', '35.1.1') returning id into nc;
    insert into public.acoes (empresa_id, nc_id, pgr_id, descricao)
    values (emp, nc, pgr, 'Ação ' || e) returning id into acao;
    insert into public.treinamentos (empresa_id, nome, nr_ref)
    values (emp, 'Trabalho em altura', 'NR-35') returning id into trei;
    insert into public.treinamentos_realizados (empresa_id, trabalhador_id, treinamento_id, data_realizacao)
    values (emp, trab, trei, current_date);
    insert into public.asos (empresa_id, trabalhador_id, tipo, data_exame, resultado, medico_nome, medico_crm)
    values (emp, trab, 'admissional', current_date, 'apto', 'Médico Teste', 'CRM 000000');
    insert into storage.objects (bucket_id, name) values ('documentos', emp || '/fixture.pdf');

    insert into fx values
      ('emp_' || e, emp), ('estab_' || e, estab), ('trab_' || e, trab), ('pgr_' || e, pgr),
      ('nc_' || e, nc), ('acao_' || e, acao), ('trei_' || e, trei);
  end loop;

  -- Empresa C inativa: vínculo ativo nela não pode dar acesso.
  insert into public.empresas (razao_social, cnpj, ativo)
  values ('Empresa C', repeat('3', 14), false) returning id into emp;
  insert into public.nao_conformidades (empresa_id, origem, descricao)
  values (emp, 'inspecao', 'NC C');
  insert into fx values ('emp_C', emp);

  insert into storage.buckets (id, name, public) values ('outro', 'outro', false);

  insert into public.membros (usuario_id, empresa_id, papel, ativo) values
    (pg_temp.fx('u_a_admin'),   pg_temp.fx('emp_A'), 'admin',           true),
    (pg_temp.fx('u_a_tec'),     pg_temp.fx('emp_A'), 'tecnico_sst',     true),
    (pg_temp.fx('u_a_med'),     pg_temp.fx('emp_A'), 'medico',          true),
    (pg_temp.fx('u_a_cli'),     pg_temp.fx('emp_A'), 'cliente_leitura', true),
    (pg_temp.fx('u_b_admin'),   pg_temp.fx('emp_B'), 'admin',           true),
    (pg_temp.fx('u_b_tec'),     pg_temp.fx('emp_B'), 'tecnico_sst',     true),
    (pg_temp.fx('u_b_med'),     pg_temp.fx('emp_B'), 'medico',          true),
    (pg_temp.fx('u_b_cli'),     pg_temp.fx('emp_B'), 'cliente_leitura', true),
    (pg_temp.fx('u_duplo'),     pg_temp.fx('emp_A'), 'tecnico_sst',     true),
    (pg_temp.fx('u_duplo'),     pg_temp.fx('emp_B'), 'cliente_leitura', true),
    (pg_temp.fx('u_duplo_tec'), pg_temp.fx('emp_A'), 'tecnico_sst',     true),
    (pg_temp.fx('u_duplo_tec'), pg_temp.fx('emp_B'), 'tecnico_sst',     true),
    (pg_temp.fx('u_inativo'),   pg_temp.fx('emp_A'), 'admin',           false),
    (pg_temp.fx('u_c_tec'),     pg_temp.fx('emp_C'), 'tecnico_sst',     true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Execução como usuário
-- ---------------------------------------------------------------------------
create function pg_temp.medir(usuario text, comando text) returns text
language plpgsql as $$
declare
  uid uuid := pg_temp.fx('u_' || usuario);
  n bigint;
  resultado text;
begin
  begin
    if usuario = 'anon' then
      perform set_config('request.jwt.claims', '{"role":"anon"}', true);
      set local role anon;
    else
      perform set_config('request.jwt.claims',
        json_build_object('sub', uid, 'role', 'authenticated')::text, true);
      set local role authenticated;
    end if;

    if comando ~* '^\s*(select|with)\s' then
      execute comando into n;
      resultado := 'linhas=' || n;
    else
      execute comando;
      get diagnostics n = row_count;
      resultado := 'ok=' || n;
    end if;
    -- Aborta a subtransação: desfaz o DML e o SET LOCAL ROLE.
    raise exception using errcode = 'KJ999';
  exception
    when sqlstate 'KJ999' then null;
    when others then resultado := 'erro=' || sqlstate;
  end;
  if current_user <> 'postgres' then
    raise exception 'medir() não restaurou o papel: %', current_user;
  end if;
  return resultado;
end;
$$;

create temp table casos (
  ordem     serial,
  descricao text not null,
  obtido    text not null,
  esperado  text not null
) on commit drop;

create function pg_temp.caso(descricao text, usuario text, comando text, esperado text)
returns void language sql as $$
  insert into casos (descricao, obtido, esperado)
  values (usuario || ': ' || descricao, pg_temp.medir(usuario, comando), esperado)
$$;

-- INSERT válido (FKs apontando para linhas da mesma empresa-alvo), para que a única
-- razão de falha seja a RLS.
create function pg_temp.sql_insert(tabela text, e text) returns text
language sql stable as $$
  select case tabela
    when 'estabelecimentos' then format(
      $q$insert into public.estabelecimentos (empresa_id, tipo, nome) values (%L, 'obra', 'nova')$q$,
      pg_temp.fx('emp_' || e))
    when 'trabalhadores' then format(
      $q$insert into public.trabalhadores (empresa_id, nome, cpf) values (%L, 'novo', '99999999999')$q$,
      pg_temp.fx('emp_' || e))
    when 'pgrs' then format(
      $q$insert into public.pgrs (empresa_id, versao, data_elaboracao) values (%L, '2', current_date)$q$,
      pg_temp.fx('emp_' || e))
    when 'nao_conformidades' then format(
      $q$insert into public.nao_conformidades (empresa_id, origem, descricao) values (%L, 'inspecao', 'nova')$q$,
      pg_temp.fx('emp_' || e))
    when 'acoes' then format(
      $q$insert into public.acoes (empresa_id, nc_id, descricao) values (%L, %L, 'nova')$q$,
      pg_temp.fx('emp_' || e), pg_temp.fx('nc_' || e))
    when 'treinamentos' then format(
      $q$insert into public.treinamentos (empresa_id, nome) values (%L, 'novo')$q$,
      pg_temp.fx('emp_' || e))
    when 'treinamentos_realizados' then format(
      $q$insert into public.treinamentos_realizados (empresa_id, trabalhador_id, treinamento_id, data_realizacao)
         values (%L, %L, %L, current_date)$q$,
      pg_temp.fx('emp_' || e), pg_temp.fx('trab_' || e), pg_temp.fx('trei_' || e))
    when 'asos' then format(
      $q$insert into public.asos (empresa_id, trabalhador_id, tipo, data_exame, resultado, medico_nome, medico_crm)
         values (%L, %L, 'periodico', current_date, 'apto', 'Médico', 'CRM 1')$q$,
      pg_temp.fx('emp_' || e), pg_temp.fx('trab_' || e))
  end
$$;

-- ---------------------------------------------------------------------------
-- 1. Matriz: 8 usuários × 8 tabelas de negócio × 7 operações = 448 casos
-- ---------------------------------------------------------------------------
do $$
declare
  usu record;
  tabela text;
  outra text;
  escreve boolean;
begin
  for usu in
    select * from (values
      ('a_admin', 'A', 'admin'), ('a_tec', 'A', 'tecnico_sst'),
      ('a_med',   'A', 'medico'), ('a_cli', 'A', 'cliente_leitura'),
      ('b_admin', 'B', 'admin'), ('b_tec', 'B', 'tecnico_sst'),
      ('b_med',   'B', 'medico'), ('b_cli', 'B', 'cliente_leitura')
    ) as v (nome, empresa, papel)
  loop
    outra := case usu.empresa when 'A' then 'B' else 'A' end;
    foreach tabela in array array[
      'estabelecimentos', 'trabalhadores', 'pgrs', 'nao_conformidades',
      'acoes', 'treinamentos', 'treinamentos_realizados', 'asos'
    ] loop
      escreve := case tabela
        when 'asos' then usu.papel = 'medico'
        else usu.papel in ('admin', 'tecnico_sst')
      end;

      perform pg_temp.caso(format('%s lê só a própria empresa', tabela), usu.nome,
        format('select count(*) from public.%I', tabela), 'linhas=1');
      perform pg_temp.caso(format('%s não lê a outra empresa', tabela), usu.nome,
        format('select count(*) from public.%I where empresa_id = %L', tabela, pg_temp.fx('emp_' || outra)),
        'linhas=0');
      perform pg_temp.caso(format('%s insere na própria empresa conforme papel', tabela), usu.nome,
        pg_temp.sql_insert(tabela, usu.empresa), case when escreve then 'ok=1' else 'erro=42501' end);
      perform pg_temp.caso(format('%s não insere na outra empresa', tabela), usu.nome,
        pg_temp.sql_insert(tabela, outra), 'erro=42501');
      perform pg_temp.caso(format('%s altera na própria empresa conforme papel', tabela), usu.nome,
        format('update public.%I set updated_at = now() where empresa_id = %L', tabela, pg_temp.fx('emp_' || usu.empresa)),
        case when escreve then 'ok=1' else 'ok=0' end);
      perform pg_temp.caso(format('%s não altera a outra empresa', tabela), usu.nome,
        format('update public.%I set updated_at = now() where empresa_id = %L', tabela, pg_temp.fx('emp_' || outra)),
        'ok=0');
      perform pg_temp.caso(format('%s sem exclusão física', tabela), usu.nome,
        format('delete from public.%I where empresa_id = %L', tabela, pg_temp.fx('emp_' || usu.empresa)),
        'erro=42501');
    end loop;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. anon, usuário sem vínculo, vínculo inativo, empresa inativa
-- ---------------------------------------------------------------------------
do $$
declare
  tabela text;
begin
  foreach tabela in array array[
    'empresas', 'membros', 'estabelecimentos', 'trabalhadores', 'pgrs', 'nao_conformidades',
    'acoes', 'treinamentos', 'treinamentos_realizados', 'asos'
  ] loop
    perform pg_temp.caso(format('%s negado ao anon', tabela), 'anon',
      format('select count(*) from public.%I', tabela), 'erro=42501');
    perform pg_temp.caso(format('%s vazio para quem não tem vínculo', tabela), 'sem_vinculo',
      format('select count(*) from public.%I', tabela), 'linhas=0');
    perform pg_temp.caso(format('%s vazio com vínculo inativo', tabela), 'inativo',
      format('select count(*) from public.%I where %I = %L', tabela,
             case tabela when 'empresas' then 'id' else 'empresa_id' end, pg_temp.fx('emp_A')),
      'linhas=0');
  end loop;
end;
$$;

select pg_temp.caso('não insere NC sem vínculo', 'sem_vinculo',
  pg_temp.sql_insert('nao_conformidades', 'A'), 'erro=42501');
select pg_temp.caso('vínculo em empresa inativa não dá leitura', 'c_tec',
  'select count(*) from public.nao_conformidades', 'linhas=0');
select pg_temp.caso('vínculo em empresa inativa não dá escrita', 'c_tec',
  format($q$insert into public.nao_conformidades (empresa_id, origem, descricao) values (%L, 'inspecao', 'x')$q$,
         pg_temp.fx('emp_C')), 'erro=42501');

-- ---------------------------------------------------------------------------
-- 3. Usuário em duas empresas: o papel vale por empresa
-- ---------------------------------------------------------------------------
select pg_temp.caso('lê NCs das duas empresas', 'duplo',
  'select count(*) from public.nao_conformidades', 'linhas=2');
select pg_temp.caso('técnico em A insere NC em A', 'duplo',
  pg_temp.sql_insert('nao_conformidades', 'A'), 'ok=1');
select pg_temp.caso('cliente em B não insere NC em B', 'duplo',
  pg_temp.sql_insert('nao_conformidades', 'B'), 'erro=42501');
select pg_temp.caso('cliente em B não altera NC de B', 'duplo',
  format('update public.nao_conformidades set descricao = $$x$$ where empresa_id = %L', pg_temp.fx('emp_B')), 'ok=0');

-- ---------------------------------------------------------------------------
-- 4. Travas estruturais contra vazamento entre empresas
-- ---------------------------------------------------------------------------
select pg_temp.caso('não move NC de A para B (escreve nas duas)', 'duplo_tec',
  format('update public.nao_conformidades set empresa_id = %L where id = %L',
         pg_temp.fx('emp_B'), pg_temp.fx('nc_A')), 'erro=KJ002');
select pg_temp.caso('não move ação de A para B (escreve nas duas)', 'duplo_tec',
  format('update public.acoes set empresa_id = %L where id = %L',
         pg_temp.fx('emp_B'), pg_temp.fx('acao_A')), 'erro=KJ002');
select pg_temp.caso('ação em A não referencia NC de B (FK composta)', 'duplo_tec',
  format($q$insert into public.acoes (empresa_id, nc_id, descricao) values (%L, %L, 'x')$q$,
         pg_temp.fx('emp_A'), pg_temp.fx('nc_B')), 'erro=23503');
select pg_temp.caso('ação em A não referencia NC de B, mesmo sabendo o uuid', 'a_tec',
  format($q$insert into public.acoes (empresa_id, nc_id, descricao) values (%L, %L, 'x')$q$,
         pg_temp.fx('emp_A'), pg_temp.fx('nc_B')), 'erro=23503');
select pg_temp.caso('ASO em A não referencia trabalhador de B', 'a_med',
  format($q$insert into public.asos (empresa_id, trabalhador_id, tipo, data_exame, resultado, medico_nome, medico_crm)
            values (%L, %L, 'periodico', current_date, 'apto', 'M', 'CRM')$q$,
         pg_temp.fx('emp_A'), pg_temp.fx('trab_B')), 'erro=23503');
select pg_temp.caso('created_by não é forjável', 'a_tec',
  format($q$with i as (
              insert into public.nao_conformidades (empresa_id, origem, descricao, created_by)
              values (%L, 'inspecao', 'x', %L) returning created_by)
            select count(*) from i where created_by = %L$q$,
         pg_temp.fx('emp_A'), pg_temp.fx('u_a_admin'), pg_temp.fx('u_a_tec')), 'linhas=1');
select pg_temp.caso('progresso de ação fora de 0–100 é recusado', 'a_tec',
  format($q$insert into public.acoes (empresa_id, descricao, progresso) values (%L, 'x', 101)$q$,
         pg_temp.fx('emp_A')), 'erro=23514');
select pg_temp.caso('prazo da NC anterior à identificação é recusado', 'a_tec',
  format($q$insert into public.nao_conformidades (empresa_id, origem, descricao, data_identificacao, prazo)
            values (%L, 'inspecao', 'x', current_date, current_date - 1)$q$,
         pg_temp.fx('emp_A')), 'erro=23514');
select pg_temp.caso('origem_externa_id idempotente por empresa', 'a_tec',
  format($q$insert into public.nao_conformidades (empresa_id, origem, origem_externa_id, descricao)
            values (%1$L, 'auditoria_nr', 'foto-1', 'x'), (%1$L, 'auditoria_nr', 'foto-1', 'y')$q$,
         pg_temp.fx('emp_A')), 'erro=23505');

-- ---------------------------------------------------------------------------
-- 5. empresas
-- ---------------------------------------------------------------------------
select pg_temp.caso('cliente vê só a própria empresa', 'a_cli',
  'select count(*) from public.empresas', 'linhas=1');
select pg_temp.caso('admin altera a própria empresa', 'a_admin',
  format('update public.empresas set razao_social = $$A2$$ where id = %L', pg_temp.fx('emp_A')), 'ok=1');
select pg_temp.caso('técnico não altera a empresa', 'a_tec',
  format('update public.empresas set razao_social = $$A2$$ where id = %L', pg_temp.fx('emp_A')), 'ok=0');
select pg_temp.caso('admin não altera outra empresa', 'a_admin',
  format('update public.empresas set razao_social = $$B2$$ where id = %L', pg_temp.fx('emp_B')), 'ok=0');
select pg_temp.caso('admin não cria empresa pela API', 'a_admin',
  $q$insert into public.empresas (razao_social, cnpj) values ('Nova', '44444444444444')$q$, 'erro=42501');
select pg_temp.caso('admin não exclui empresa', 'a_admin',
  format('delete from public.empresas where id = %L', pg_temp.fx('emp_A')), 'erro=42501');

-- ---------------------------------------------------------------------------
-- 6. membros
-- ---------------------------------------------------------------------------
select pg_temp.caso('técnico vê só o próprio vínculo', 'a_tec',
  'select count(*) from public.membros', 'linhas=1');
select pg_temp.caso('admin vê todos os vínculos da empresa e nenhum de fora', 'a_admin',
  'select count(*) from public.membros', 'linhas=7');
select pg_temp.caso('admin adiciona membro na própria empresa', 'a_admin',
  format($q$insert into public.membros (usuario_id, empresa_id, papel) values (%L, %L, 'cliente_leitura')$q$,
         pg_temp.fx('u_sem_vinculo'), pg_temp.fx('emp_A')), 'ok=1');
select pg_temp.caso('admin não adiciona membro em outra empresa', 'a_admin',
  format($q$insert into public.membros (usuario_id, empresa_id, papel) values (%L, %L, 'admin')$q$,
         pg_temp.fx('u_a_admin'), pg_temp.fx('emp_B')), 'erro=42501');
select pg_temp.caso('técnico não adiciona membro', 'a_tec',
  format($q$insert into public.membros (usuario_id, empresa_id, papel) values (%L, %L, 'cliente_leitura')$q$,
         pg_temp.fx('u_sem_vinculo'), pg_temp.fx('emp_A')), 'erro=42501');
select pg_temp.caso('técnico não se promove a admin', 'a_tec',
  format($q$update public.membros set papel = 'admin' where usuario_id = %L$q$, pg_temp.fx('u_a_tec')), 'ok=0');
select pg_temp.caso('admin altera papel de membro da própria empresa', 'a_admin',
  format($q$update public.membros set papel = 'tecnico_sst' where usuario_id = %L$q$, pg_temp.fx('u_a_cli')), 'ok=1');
select pg_temp.caso('admin não altera membro de outra empresa', 'a_admin',
  format($q$update public.membros set papel = 'admin' where usuario_id = %L$q$, pg_temp.fx('u_b_cli')), 'ok=0');
select pg_temp.caso('admin não exclui membro de outra empresa', 'a_admin',
  format('delete from public.membros where usuario_id = %L', pg_temp.fx('u_b_cli')), 'ok=0');
select pg_temp.caso('admin exclui membro da própria empresa', 'a_admin',
  format('delete from public.membros where usuario_id = %L', pg_temp.fx('u_a_cli')), 'ok=1');
select pg_temp.caso('último admin não se rebaixa', 'a_admin',
  format($q$update public.membros set papel = 'tecnico_sst' where usuario_id = %L$q$, pg_temp.fx('u_a_admin')), 'erro=KJ001');
select pg_temp.caso('último admin não se desativa', 'a_admin',
  format('update public.membros set ativo = false where usuario_id = %L', pg_temp.fx('u_a_admin')), 'erro=KJ001');
select pg_temp.caso('último admin não se exclui', 'a_admin',
  format('delete from public.membros where usuario_id = %L', pg_temp.fx('u_a_admin')), 'erro=KJ001');
select pg_temp.caso('admin não move vínculo para outra empresa', 'a_admin',
  format('update public.membros set empresa_id = %L where usuario_id = %L',
         pg_temp.fx('emp_B'), pg_temp.fx('u_a_cli')), 'erro=KJ002');

-- ---------------------------------------------------------------------------
-- 7. Storage: bucket "documentos", caminho {empresa_id}/...
-- ---------------------------------------------------------------------------
select pg_temp.caso('storage: cliente lê só arquivos da própria empresa', 'a_cli',
  $q$select count(*) from storage.objects where bucket_id = 'documentos'$q$, 'linhas=1');
select pg_temp.caso('storage: anon não lê nada', 'anon',
  $q$select count(*) from storage.objects$q$, 'linhas=0');
select pg_temp.caso('storage: técnico grava na própria empresa', 'a_tec',
  format($q$insert into storage.objects (bucket_id, name) values ('documentos', %L)$q$,
         pg_temp.fx('emp_A') || '/pgr/v2.pdf'), 'ok=1');
select pg_temp.caso('storage: médico grava na própria empresa', 'a_med',
  format($q$insert into storage.objects (bucket_id, name) values ('documentos', %L)$q$,
         pg_temp.fx('emp_A') || '/aso/1.pdf'), 'ok=1');
select pg_temp.caso('storage: técnico não grava em outra empresa', 'a_tec',
  format($q$insert into storage.objects (bucket_id, name) values ('documentos', %L)$q$,
         pg_temp.fx('emp_B') || '/x.pdf'), 'erro=42501');
select pg_temp.caso('storage: cliente não grava', 'a_cli',
  format($q$insert into storage.objects (bucket_id, name) values ('documentos', %L)$q$,
         pg_temp.fx('emp_A') || '/x.pdf'), 'erro=42501');
select pg_temp.caso('storage: caminho fora do padrão é negado, não quebra', 'a_admin',
  $q$insert into storage.objects (bucket_id, name) values ('documentos', 'nao-e-uuid/x.pdf')$q$, 'erro=42501');
select pg_temp.caso('storage: arquivo na raiz do bucket é negado', 'a_admin',
  $q$insert into storage.objects (bucket_id, name) values ('documentos', 'x.pdf')$q$, 'erro=42501');
select pg_temp.caso('storage: outro bucket sem política é negado', 'a_admin',
  format($q$insert into storage.objects (bucket_id, name) values ('outro', %L)$q$,
         pg_temp.fx('emp_A') || '/x.pdf'), 'erro=42501');
-- O Supabase bloqueia DELETE direto em storage.objects (storage.protect_delete); a API de
-- Storage liga storage.allow_delete_query antes de excluir. Primeiro o bloqueio, depois a
-- política medida pelo mesmo caminho da API.
select pg_temp.caso('storage: DELETE direto por SQL é bloqueado', 'a_admin',
  $q$delete from storage.objects where bucket_id = 'documentos'$q$, 'erro=42501');
select set_config('storage.allow_delete_query', 'true', true);
select pg_temp.caso('storage: técnico não exclui', 'a_tec',
  $q$delete from storage.objects where bucket_id = 'documentos'$q$, 'ok=0');
select pg_temp.caso('storage: admin exclui só da própria empresa', 'a_admin',
  $q$delete from storage.objects where bucket_id = 'documentos'$q$, 'ok=1');
select set_config('storage.allow_delete_query', 'false', true);

-- ---------------------------------------------------------------------------
-- Asserções
-- ---------------------------------------------------------------------------
select plan((select count(*)::int + 1 from casos));

-- Guarda contra a matriz encolher sem ninguém perceber.
select is((select count(*)::int from casos), 448 + 30 + 3 + 4 + 9 + 6 + 14 + 12,
  'quantidade de casos gerados');

select is(obtido, esperado, descricao) from casos order by ordem;

select * from finish();
rollback;
