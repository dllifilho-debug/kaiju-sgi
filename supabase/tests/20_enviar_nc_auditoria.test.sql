-- "Enviar para o Kaiju" (migration 0005): permissões, atomicidade e idempotência de
-- public.enviar_nc_auditoria. Mesmo método de 10_isolamento: cada caso roda como um usuário
-- numa subtransação desfeita; o resultado vira texto comparável.
begin;
create extension if not exists pgtap with schema extensions;

-- No script único do SQL Editor este arquivo roda na mesma transação de 10_isolamento, que
-- deixa o claim como texto vazio: auth.uid() quebraria no ''::jsonb ao gravar as fixtures.
select set_config('request.jwt.claims', '{}', true);

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create temp table e5_fx (chave text primary key, id uuid not null) on commit drop;

create function pg_temp.e5_fx(k text) returns uuid language sql stable as $$
  select id from e5_fx where chave = k
$$;

do $$
declare
  u text;
  e text;
  emp uuid;
  estab uuid;
begin
  foreach u in array array['a_admin', 'a_tec', 'a_med', 'a_cli', 'b_tec', 'duplo_tec'] loop
    insert into e5_fx values ('u_' || u, gen_random_uuid());
    insert into auth.users (id, email) values (pg_temp.e5_fx('u_' || u), 'e5_' || u || '@teste.kaiju.invalid');
  end loop;

  foreach e in array array['A', 'B'] loop
    insert into public.empresas (razao_social, cnpj)
    values ('Empresa ' || e, repeat(case e when 'A' then '5' else '6' end, 14))
    returning id into emp;
    insert into public.estabelecimentos (empresa_id, tipo, nome)
    values (emp, 'obra', 'Obra ' || e) returning id into estab;
    insert into e5_fx values ('emp_' || e, emp), ('estab_' || e, estab);
  end loop;

  insert into public.membros (usuario_id, empresa_id, papel) values
    (pg_temp.e5_fx('u_a_admin'),   pg_temp.e5_fx('emp_A'), 'admin'),
    (pg_temp.e5_fx('u_a_tec'),     pg_temp.e5_fx('emp_A'), 'tecnico_sst'),
    (pg_temp.e5_fx('u_a_med'),     pg_temp.e5_fx('emp_A'), 'medico'),
    (pg_temp.e5_fx('u_a_cli'),     pg_temp.e5_fx('emp_A'), 'cliente_leitura'),
    (pg_temp.e5_fx('u_b_tec'),     pg_temp.e5_fx('emp_B'), 'tecnico_sst'),
    (pg_temp.e5_fx('u_duplo_tec'), pg_temp.e5_fx('emp_A'), 'tecnico_sst'),
    (pg_temp.e5_fx('u_duplo_tec'), pg_temp.e5_fx('emp_B'), 'tecnico_sst');
end;
$$;

-- Item no formato que o app-auditoria-nrs envia.
create function pg_temp.e5_item(ref text, severidade text default 'alta', prazo text default null)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'origem_externa_id', ref,
    'titulo', 'NR-18 18.13.1 — proteção contra queda',
    'descricao', 'Periferia da laje sem guarda-corpo.',
    'norma_ref', 'NR-18', 'item_ref', '18.13.1',
    'severidade', severidade, 'setor', 'Obra',
    'data_identificacao', '2026-10-08', 'prazo', coalesce(prazo, '2026-10-15'),
    'acao', jsonb_build_object(
      'titulo', 'Instalar guarda-corpo', 'descricao', 'Instalar guarda-corpo na periferia.',
      'prioridade', severidade, 'prazo', coalesce(prazo, '2026-10-15')))
$$;

create function pg_temp.e5_lote(e text, itens jsonb, estab text default null) returns text
language sql stable as $$
  select format('public.enviar_nc_auditoria(%L, %L, %L::jsonb)',
                pg_temp.e5_fx('emp_' || e), pg_temp.e5_fx('estab_' || coalesce(estab, e)), itens)
$$;

-- ---------------------------------------------------------------------------
-- Execução como usuário
-- ---------------------------------------------------------------------------
create function pg_temp.e5_entrar(usuario text) returns void language plpgsql as $$
begin
  if usuario = 'anon' then
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    set local role anon;
  else
    perform set_config('request.jwt.claims',
      json_build_object('sub', pg_temp.e5_fx('u_' || usuario), 'role', 'authenticated')::text, true);
    set local role authenticated;
  end if;
end;
$$;

-- Mede e desfaz: 'linhas=N' para consulta, 'erro=XXXXX' para SQLSTATE.
create function pg_temp.e5_medir(usuario text, consulta text) returns text
language plpgsql as $$
declare
  n bigint;
  resultado text;
begin
  begin
    perform pg_temp.e5_entrar(usuario);
    execute consulta into n;
    resultado := 'linhas=' || n;
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

-- Executa como usuário e MANTÉM o efeito (estado para os e5_casos seguintes).
create function pg_temp.e5_gravar(usuario text, chamada text) returns void
language plpgsql as $$
begin
  perform pg_temp.e5_entrar(usuario);
  execute 'select ' || chamada;
  perform set_config('request.jwt.claims', '{}', true);
  reset role;
end;
$$;

create temp table e5_casos (
  ordem     serial,
  descricao text not null,
  obtido    text not null,
  esperado  text not null
) on commit drop;

create function pg_temp.e5_caso(descricao text, usuario text, consulta text, esperado text)
returns void language sql as $$
  insert into e5_casos (descricao, obtido, esperado)
  values (usuario || ': ' || descricao, pg_temp.e5_medir(usuario, consulta), esperado)
$$;

-- Contagem de linhas como postgres (sem RLS), para conferir o que ficou gravado.
create function pg_temp.e5_contar(consulta text) returns text language plpgsql as $$
declare
  n bigint;
begin
  execute consulta into n;
  return 'linhas=' || n;
end;
$$;

create function pg_temp.e5_conferir(descricao text, consulta text, esperado text)
returns void language sql as $$
  insert into e5_casos (descricao, obtido, esperado)
  values ('estado: ' || descricao, pg_temp.e5_contar(consulta), esperado)
$$;

-- ---------------------------------------------------------------------------
-- 1. Permissões: só admin/tecnico_sst da própria empresa
-- ---------------------------------------------------------------------------
select pg_temp.e5_caso('técnico envia lote de 2 itens', 'a_tec',
  format($q$select count(*) from jsonb_array_elements(%s) e where e->>'situacao' = 'criada'$q$,
         pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('f1'), pg_temp.e5_item('f2')))), 'linhas=2');
select pg_temp.e5_caso('admin envia', 'a_admin',
  format('select jsonb_array_length(%s)', pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('f1')))), 'linhas=1');
select pg_temp.e5_caso('médico não envia (não escreve NC)', 'a_med',
  format('select jsonb_array_length(%s)', pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('f1')))), 'erro=42501');
select pg_temp.e5_caso('cliente não envia', 'a_cli',
  format('select jsonb_array_length(%s)', pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('f1')))), 'erro=42501');
select pg_temp.e5_caso('técnico de B não envia para A', 'b_tec',
  format('select jsonb_array_length(%s)', pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('f1')))), 'erro=42501');
select pg_temp.e5_caso('anon não executa a função', 'anon',
  format('select jsonb_array_length(%s)', pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('f1')))), 'erro=42501');
select pg_temp.e5_caso('obra de B não entra em lote de A (FK composta)', 'duplo_tec',
  format('select jsonb_array_length(%s)', pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('f1')), 'B')), 'erro=23503');

-- ---------------------------------------------------------------------------
-- 2. Validação do payload (KJ003) e atomicidade
-- ---------------------------------------------------------------------------
select pg_temp.e5_caso('itens vazio é recusado', 'a_tec',
  format('select jsonb_array_length(%s)', pg_temp.e5_lote('A', '[]'::jsonb)), 'erro=KJ003');
select pg_temp.e5_caso('itens que não é lista é recusado', 'a_tec',
  format('select jsonb_array_length(%s)', pg_temp.e5_lote('A', pg_temp.e5_item('f1'))), 'erro=KJ003');
select pg_temp.e5_caso('item sem origem_externa_id é recusado', 'a_tec',
  format('select jsonb_array_length(%s)',
         pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('f1') - 'origem_externa_id'))), 'erro=KJ003');
select pg_temp.e5_caso('item sem descricao é recusado', 'a_tec',
  format('select jsonb_array_length(%s)',
         pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('f1') - 'descricao'))), 'erro=KJ003');
select pg_temp.e5_caso('ação sem descricao é recusada', 'a_tec',
  format('select jsonb_array_length(%s)',
         pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('f1') #- '{acao,descricao}'))), 'erro=KJ003');
select pg_temp.e5_caso('severidade fora do enum é recusada', 'a_tec',
  format('select jsonb_array_length(%s)',
         pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('f1', 'gravissima')))), 'erro=22P02');
select pg_temp.e5_caso('prazo anterior à inspeção é recusado', 'a_tec',
  format('select jsonb_array_length(%s)',
         pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('f1', 'alta', '2026-10-01')))), 'erro=23514');
-- Item 1 válido + item 2 inválido: a chamada inteira falha. Que nada do item 1 sobra é
-- garantia do Postgres (erro numa instrução desfaz tudo o que ela fez); o que o teste fixa é
-- que o erro do item 2 chega a quem chamou, em vez de ser engolido item a item.
select pg_temp.e5_caso('lote com um item inválido é recusado inteiro', 'a_tec',
  format('select jsonb_array_length(%s)',
         pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('ok-1'), pg_temp.e5_item('ruim', 'gravissima')))),
  'erro=22P02');

-- ---------------------------------------------------------------------------
-- 3. Gravação e idempotência (com estado mantido)
-- ---------------------------------------------------------------------------
select pg_temp.e5_gravar('a_tec', pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('f1'), pg_temp.e5_item('f2'))));

select pg_temp.e5_conferir('2 NCs de auditoria_nr em A',
  format($q$select count(*) from public.nao_conformidades
            where empresa_id = %L and origem = 'auditoria_nr' and status = 'aberta'$q$, pg_temp.e5_fx('emp_A')),
  'linhas=2');
select pg_temp.e5_conferir('NC com norma, item, severidade, obra e prazo',
  format($q$select count(*) from public.nao_conformidades
            where origem_externa_id = 'f1' and norma_ref = 'NR-18' and item_ref = '18.13.1'
              and severidade = 'alta' and estabelecimento_id = %L
              and data_identificacao = '2026-10-08' and prazo = '2026-10-15'$q$, pg_temp.e5_fx('estab_A')),
  'linhas=1');
select pg_temp.e5_conferir('autoria é o técnico logado',
  format($q$select count(*) from public.nao_conformidades
            where origem = 'auditoria_nr' and created_by = %L$q$, pg_temp.e5_fx('u_a_tec')), 'linhas=2');
select pg_temp.e5_conferir('cada NC com 1 ação corretiva pendente vinculada',
  $q$select count(*) from public.acoes a join public.nao_conformidades nc
       on nc.empresa_id = a.empresa_id and nc.id = a.nc_id
     where nc.empresa_id in (select id from e5_fx where chave like 'emp_%') and nc.origem = 'auditoria_nr' and a.tipo = 'corretiva' and a.status = 'pendente'
       and a.prioridade = 'alta' and a.prazo = '2026-10-15'$q$, 'linhas=2');

select pg_temp.e5_caso('reenvio devolve ja_existia', 'a_tec',
  format($q$select count(*) from jsonb_array_elements(%s) e where e->>'situacao' = 'ja_existia'$q$,
         pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('f1'), pg_temp.e5_item('f2')))), 'linhas=2');
select pg_temp.e5_caso('reenvio devolve o id da NC existente', 'a_tec',
  format($q$select count(*) from jsonb_array_elements(%s) e
            join public.nao_conformidades nc on nc.id = (e->>'nc_id')::uuid$q$,
         pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('f1')))), 'linhas=1');

-- NC já tratada no Kaiju: o reenvio não pode desfazer o tratamento.
update public.nao_conformidades
   set status = 'em_tratamento', descricao = 'editada no Kaiju'
 where empresa_id = pg_temp.e5_fx('emp_A') and origem_externa_id = 'f1';
select pg_temp.e5_gravar('a_tec', pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('f1'), pg_temp.e5_item('f2'))));

select pg_temp.e5_conferir('reenvio não duplica NC',
  $q$select count(*) from public.nao_conformidades nc
     where nc.empresa_id in (select id from e5_fx where chave like 'emp_%') and nc.origem = 'auditoria_nr'$q$, 'linhas=2');
select pg_temp.e5_conferir('reenvio não duplica ação',
  $q$select count(*) from public.acoes a join public.nao_conformidades nc on nc.id = a.nc_id
     where nc.empresa_id in (select id from e5_fx where chave like 'emp_%') and nc.origem = 'auditoria_nr'$q$, 'linhas=2');
select pg_temp.e5_conferir('reenvio não sobrescreve NC tratada',
  $q$select count(*) from public.nao_conformidades nc
     where nc.empresa_id in (select id from e5_fx where chave like 'emp_%') and origem_externa_id = 'f1' and status = 'em_tratamento' and descricao = 'editada no Kaiju'$q$,
  'linhas=1');

select pg_temp.e5_caso('lote misto: 1 nova + 1 existente', 'a_tec',
  format($q$select count(*) from jsonb_array_elements(%s) e
            where (e->>'origem_externa_id', e->>'situacao') in (('f2', 'ja_existia'), ('f3', 'criada'))$q$,
         pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('f2'), pg_temp.e5_item('f3')))), 'linhas=2');
select pg_temp.e5_caso('cliente não envia nem item que já existe', 'a_cli',
  format('select jsonb_array_length(%s)', pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('f1')))), 'erro=42501');
select pg_temp.e5_caso('item sem ação grava só a NC', 'a_tec',
  format($q$select count(*) from public.acoes a join public.nao_conformidades nc on nc.id = a.nc_id
            where nc.origem_externa_id = 'sem-acao' and jsonb_array_length(%s) = 1$q$,
         pg_temp.e5_lote('A', jsonb_build_array(pg_temp.e5_item('sem-acao') - 'acao'))), 'linhas=0');

-- A mesma chave em outra empresa é outra NC.
select pg_temp.e5_gravar('duplo_tec', pg_temp.e5_lote('B', jsonb_build_array(pg_temp.e5_item('f1'))));
select pg_temp.e5_conferir('mesma origem_externa_id em A e B são NCs distintas',
  $q$select count(*) from public.nao_conformidades nc
     where nc.empresa_id in (select id from e5_fx where chave like 'emp_%') and origem_externa_id = 'f1'$q$, 'linhas=2');
select pg_temp.e5_caso('técnico de B não vê a NC de A pelo retorno', 'b_tec',
  format($q$select count(*) from public.nao_conformidades where empresa_id = %L$q$, pg_temp.e5_fx('emp_A')),
  'linhas=0');

-- ---------------------------------------------------------------------------
-- Asserções
-- ---------------------------------------------------------------------------
select plan((select count(*)::int + 4 from e5_casos));

select is((select count(*)::int from e5_casos), 7 + 8 + 4 + 2 + 3 + 3 + 2, 'quantidade de e5_casos gerados');

select is(
  (select prosecdef from pg_proc where oid = 'public.enviar_nc_auditoria(uuid, uuid, jsonb)'::regprocedure),
  false, 'enviar_nc_auditoria é SECURITY INVOKER (RLS do usuário vale)');
select is(
  (select proconfig @> array['search_path=""'] from pg_proc
    where oid = 'public.enviar_nc_auditoria(uuid, uuid, jsonb)'::regprocedure),
  true, 'enviar_nc_auditoria fixa search_path vazio');
select is(
  has_function_privilege('anon', 'public.enviar_nc_auditoria(uuid, uuid, jsonb)', 'execute'),
  false, 'anon sem EXECUTE em enviar_nc_auditoria');

select is(obtido, esperado, descricao) from e5_casos order by ordem;

select * from finish();
rollback;
