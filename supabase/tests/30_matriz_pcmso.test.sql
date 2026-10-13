-- Matriz do PCMSO (migration 0006): permissões, validação, idempotência, ciclo de vida do PCMSO,
-- imutabilidade da matriz, isolamento e vínculo trabalhador → GHE. Mesmo método de
-- 20_enviar_nc_auditoria: cada caso roda como um usuário numa subtransação desfeita.
begin;
create extension if not exists pgtap with schema extensions;

select set_config('request.jwt.claims', '{}', true);

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create temp table e6_fx (chave text primary key, id uuid not null) on commit drop;

create function pg_temp.e6_fx(k text) returns uuid language sql stable as $$
  select id from e6_fx where chave = k
$$;

do $$
declare
  u text;
  e text;
  emp uuid;
  estab uuid;
  trab uuid;
begin
  foreach u in array array['a_admin', 'a_tec', 'a_med', 'a_cli', 'b_tec', 'duplo_tec'] loop
    insert into e6_fx values ('u_' || u, gen_random_uuid());
    insert into auth.users (id, email) values (pg_temp.e6_fx('u_' || u), 'e6_' || u || '@teste.kaiju.invalid');
  end loop;

  foreach e in array array['A', 'B'] loop
    insert into public.empresas (razao_social, cnpj)
    values ('Empresa e6 ' || e, repeat(case e when 'A' then '7' else '8' end, 14))
    returning id into emp;
    insert into public.estabelecimentos (empresa_id, tipo, nome)
    values (emp, 'obra', 'Obra ' || e) returning id into estab;
    insert into public.trabalhadores (empresa_id, nome, cpf, funcao)
    values (emp, 'Trabalhador ' || e, repeat(case e when 'A' then '7' else '8' end, 11), 'Carpinteiro')
    returning id into trab;
    insert into e6_fx values ('emp_' || e, emp), ('estab_' || e, estab), ('trab_' || e, trab);
  end loop;

  insert into public.membros (usuario_id, empresa_id, papel) values
    (pg_temp.e6_fx('u_a_admin'),   pg_temp.e6_fx('emp_A'), 'admin'),
    (pg_temp.e6_fx('u_a_tec'),     pg_temp.e6_fx('emp_A'), 'tecnico_sst'),
    (pg_temp.e6_fx('u_a_med'),     pg_temp.e6_fx('emp_A'), 'medico'),
    (pg_temp.e6_fx('u_a_cli'),     pg_temp.e6_fx('emp_A'), 'cliente_leitura'),
    (pg_temp.e6_fx('u_b_tec'),     pg_temp.e6_fx('emp_B'), 'tecnico_sst'),
    (pg_temp.e6_fx('u_duplo_tec'), pg_temp.e6_fx('emp_A'), 'tecnico_sst'),
    (pg_temp.e6_fx('u_duplo_tec'), pg_temp.e6_fx('emp_B'), 'tecnico_sst');
end;
$$;

-- Matriz no formato que o app PCMSO envia: 2 GHEs, o 1º com exame de periodicidade 0.
create function pg_temp.e6_matriz(ref text, pdf text, resultado text default 'OK')
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'origem_externa_id', ref,
    'resultado_motor', resultado,
    'versao_motor', 'abc1234',
    'pgr', jsonb_build_object('origem_externa_id', pdf, 'versao', 'Rev.02',
                              'data_elaboracao', '2026-03-01', 'responsavel_tecnico', 'Eng. Teste'),
    'ghes', jsonb_build_array(
      jsonb_build_object(
        'codigo', 'GHE-01', 'nome', 'Estrutura', 'cargos', jsonb_build_array('Carpinteiro', 'Armador'),
        'status', 'VÁLIDA', 'regime_aplicado', 'geral', 'aso_inexistencia_riscos', false,
        'exames', jsonb_build_array(
          jsonb_build_object('exame', 'exame_clinico', 'periodicidade_meses', 12,
                             'momentos', jsonb_build_array('ADM', 'PER', 'MR', 'RT', 'DEM')),
          jsonb_build_object('exame', 'rx_torax', 'periodicidade_meses', 0,
                             'periodicidade_apos_15a', 12, 'momentos', jsonb_build_array('ADM'))),
        'riscos_aso', jsonb_build_array(
          jsonb_build_object('risco', 'ruido', 'reconhecido', true, 'veredito', 'CONSTA',
                             'exames', jsonb_build_array('audiometria')),
          jsonb_build_object('risco', 'POEIRA DE OBRA', 'reconhecido', false, 'veredito', 'CONFERIR',
                             'exames', jsonb_build_array()))),
      jsonb_build_object(
        'codigo', 'GHE-02', 'nome', 'Administrativo', 'cargos', jsonb_build_array('Almoxarife'),
        'status', 'VÁLIDA', 'aso_inexistencia_riscos', true,
        'exames', jsonb_build_array(
          jsonb_build_object('exame', 'exame_clinico', 'periodicidade_meses', 24,
                             'momentos', jsonb_build_array('ADM', 'PER', 'RT', 'DEM'))))))
$$;

create function pg_temp.e6_envio(e text, matriz jsonb, estab text default null) returns text
language sql stable as $$
  select format('public.enviar_matriz_pcmso(%L, %L, %L::jsonb)',
                pg_temp.e6_fx('emp_' || e), pg_temp.e6_fx('estab_' || coalesce(estab, e)), matriz)
$$;

-- Atalhos de consulta sobre o retorno do envio.
create function pg_temp.e6_situacao(chamada text, situacao text) returns text language sql immutable as $$
  select format($q$select count(*) from (select %s r) x where x.r->>'situacao' = %L$q$, chamada, situacao)
$$;

create function pg_temp.e6_pcmso(ref text) returns uuid language sql stable as $$
  select id from public.pcmsos where origem_externa_id = ref and empresa_id = pg_temp.e6_fx('emp_A')
$$;

-- ---------------------------------------------------------------------------
-- Execução como usuário
-- ---------------------------------------------------------------------------
create function pg_temp.e6_entrar(usuario text) returns void language plpgsql as $$
begin
  if usuario = 'anon' then
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    set local role anon;
  else
    perform set_config('request.jwt.claims',
      json_build_object('sub', pg_temp.e6_fx('u_' || usuario), 'role', 'authenticated')::text, true);
    set local role authenticated;
  end if;
end;
$$;

-- Mede e desfaz: 'linhas=N' para consulta, 'erro=XXXXX' para SQLSTATE.
create function pg_temp.e6_medir(usuario text, consulta text) returns text
language plpgsql as $$
declare
  n bigint;
  resultado text;
begin
  begin
    perform pg_temp.e6_entrar(usuario);
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

-- Executa uma instrução como usuário e MANTÉM o efeito.
create function pg_temp.e6_gravar(usuario text, instrucao text) returns void
language plpgsql as $$
begin
  perform pg_temp.e6_entrar(usuario);
  execute instrucao;
  perform set_config('request.jwt.claims', '{}', true);
  reset role;
end;
$$;

create temp table e6_casos (
  ordem     serial,
  descricao text not null,
  obtido    text not null,
  esperado  text not null
) on commit drop;

create function pg_temp.e6_caso(descricao text, usuario text, consulta text, esperado text)
returns void language sql as $$
  insert into e6_casos (descricao, obtido, esperado)
  values (usuario || ': ' || descricao, pg_temp.e6_medir(usuario, consulta), esperado)
$$;

create function pg_temp.e6_contar(consulta text) returns text language plpgsql as $$
declare
  n bigint;
begin
  execute consulta into n;
  return 'linhas=' || n;
end;
$$;

create function pg_temp.e6_conferir(descricao text, consulta text, esperado text)
returns void language sql as $$
  insert into e6_casos (descricao, obtido, esperado)
  values ('estado: ' || descricao, pg_temp.e6_contar(consulta), esperado)
$$;

-- UPDATE medido pelo número de linhas que a RLS deixou alterar.
create function pg_temp.e6_upd(tabela text, atrib text, onde text) returns text language sql immutable as $$
  select format('with u as (update public.%I set %s where %s returning 1) select count(*) from u',
                tabela, atrib, onde)
$$;

-- ---------------------------------------------------------------------------
-- 1. Permissões de envio: admin, tecnico_sst e medico da própria empresa
-- ---------------------------------------------------------------------------
select pg_temp.e6_caso('médico envia (cria PGR e PCMSO)', 'a_med',
  pg_temp.e6_situacao(pg_temp.e6_envio('A', pg_temp.e6_matriz('p1', 'pdf-x')), 'criada'), 'linhas=1');
select pg_temp.e6_caso('técnico envia', 'a_tec',
  pg_temp.e6_situacao(pg_temp.e6_envio('A', pg_temp.e6_matriz('p1', 'pdf-x')), 'criada'), 'linhas=1');
select pg_temp.e6_caso('admin envia', 'a_admin',
  pg_temp.e6_situacao(pg_temp.e6_envio('A', pg_temp.e6_matriz('p1', 'pdf-x')), 'criada'), 'linhas=1');
select pg_temp.e6_caso('cliente não envia', 'a_cli',
  pg_temp.e6_situacao(pg_temp.e6_envio('A', pg_temp.e6_matriz('p1', 'pdf-x')), 'criada'), 'erro=42501');
select pg_temp.e6_caso('técnico de B não envia para A', 'b_tec',
  pg_temp.e6_situacao(pg_temp.e6_envio('A', pg_temp.e6_matriz('p1', 'pdf-x')), 'criada'), 'erro=42501');
select pg_temp.e6_caso('anon não executa a função', 'anon',
  pg_temp.e6_situacao(pg_temp.e6_envio('A', pg_temp.e6_matriz('p1', 'pdf-x')), 'criada'), 'erro=42501');
select pg_temp.e6_caso('obra de B não entra em envio de A (FK composta)', 'duplo_tec',
  pg_temp.e6_situacao(pg_temp.e6_envio('A', pg_temp.e6_matriz('p1', 'pdf-x'), 'B'), 'criada'), 'erro=23503');

-- ---------------------------------------------------------------------------
-- 2. Validação do payload e atomicidade
-- ---------------------------------------------------------------------------
select pg_temp.e6_caso('sem origem_externa_id é recusado', 'a_med',
  pg_temp.e6_situacao(pg_temp.e6_envio('A', pg_temp.e6_matriz('v', 'pdf-v') - 'origem_externa_id'), 'criada'), 'erro=KJ003');
select pg_temp.e6_caso('PGR sem hash é recusado', 'a_med',
  pg_temp.e6_situacao(pg_temp.e6_envio('A', pg_temp.e6_matriz('v', 'pdf-v') #- '{pgr,origem_externa_id}'), 'criada'), 'erro=KJ003');
select pg_temp.e6_caso('PGR novo sem data_elaboracao é recusado', 'a_med',
  pg_temp.e6_situacao(pg_temp.e6_envio('A', pg_temp.e6_matriz('v', 'pdf-v') #- '{pgr,data_elaboracao}'), 'criada'), 'erro=KJ003');
select pg_temp.e6_caso('ghes vazio é recusado', 'a_med',
  pg_temp.e6_situacao(pg_temp.e6_envio('A', jsonb_set(pg_temp.e6_matriz('v', 'pdf-v'), '{ghes}', '[]')), 'criada'), 'erro=KJ003');
select pg_temp.e6_caso('GHE sem código é recusado', 'a_med',
  pg_temp.e6_situacao(pg_temp.e6_envio('A', pg_temp.e6_matriz('v', 'pdf-v') #- '{ghes,1,codigo}'), 'criada'), 'erro=KJ003');
select pg_temp.e6_caso('GHE sem lista de exames é recusado', 'a_med',
  pg_temp.e6_situacao(pg_temp.e6_envio('A', pg_temp.e6_matriz('v', 'pdf-v') #- '{ghes,1,exames}'), 'criada'), 'erro=KJ003');
select pg_temp.e6_caso('momento desconhecido é recusado', 'a_med',
  pg_temp.e6_situacao(pg_temp.e6_envio('A',
    jsonb_set(pg_temp.e6_matriz('v', 'pdf-v'), '{ghes,1,exames,0,momentos}', '["XX"]')), 'criada'), 'erro=KJ003');
select pg_temp.e6_caso('resultado REJEITADO é recusado', 'a_med',
  pg_temp.e6_situacao(pg_temp.e6_envio('A', pg_temp.e6_matriz('v', 'pdf-v', 'REJEITADO')), 'criada'), 'erro=23514');
select pg_temp.e6_caso('status de GHE desconhecido é recusado', 'a_med',
  pg_temp.e6_situacao(pg_temp.e6_envio('A',
    jsonb_set(pg_temp.e6_matriz('v', 'pdf-v'), '{ghes,0,status}', '"OUTRO"')), 'criada'), 'erro=23502');
select pg_temp.e6_caso('periodicidade negativa é recusada', 'a_med',
  pg_temp.e6_situacao(pg_temp.e6_envio('A',
    jsonb_set(pg_temp.e6_matriz('v', 'pdf-v'), '{ghes,0,exames,0,periodicidade_meses}', '-1')), 'criada'), 'erro=23514');
select pg_temp.e6_caso('veredito fora do enum é recusado', 'a_med',
  pg_temp.e6_situacao(pg_temp.e6_envio('A',
    jsonb_set(pg_temp.e6_matriz('v', 'pdf-v'), '{ghes,0,riscos_aso,0,veredito}', '"TALVEZ"')), 'criada'), 'erro=22P02');
select pg_temp.e6_caso('GHE repetido no mesmo envio é recusado', 'a_med',
  pg_temp.e6_situacao(pg_temp.e6_envio('A',
    jsonb_set(pg_temp.e6_matriz('v', 'pdf-v'), '{ghes,1,codigo}', '"GHE-01"')), 'criada'), 'erro=23505');
-- Último GHE inválido: o erro chega a quem chamou e nada do envio fica (conferido no estado abaixo).
select pg_temp.e6_conferir('envios recusados não deixaram PGR, PCMSO nem GHE',
  $q$select (select count(*) from public.pgrs where origem_externa_id = 'pdf-v')
          + (select count(*) from public.pcmsos where origem_externa_id = 'v')$q$, 'linhas=0');

-- ---------------------------------------------------------------------------
-- 3. Gravação e idempotência (estado mantido)
-- ---------------------------------------------------------------------------
select pg_temp.e6_gravar('a_med', 'select ' || pg_temp.e6_envio('A', pg_temp.e6_matriz('m1', 'pdf-1')));

select pg_temp.e6_conferir('PGR criado em rascunho, pelo médico, com o hash e a data de emissão',
  format($q$select count(*) from public.pgrs where empresa_id = %L and origem_externa_id = 'pdf-1'
            and status = 'rascunho' and versao = 'Rev.02' and data_elaboracao = '2026-03-01'
            and estabelecimento_id = %L and created_by = %L$q$,
         pg_temp.e6_fx('emp_A'), pg_temp.e6_fx('estab_A'), pg_temp.e6_fx('u_a_med')), 'linhas=1');
select pg_temp.e6_conferir('PCMSO em rascunho, resultado OK, sem médico responsável ainda',
  $q$select count(*) from public.pcmsos where origem_externa_id = 'm1' and status = 'rascunho'
       and resultado_motor = 'OK' and versao_motor = 'abc1234' and medico_responsavel_crm is null$q$, 'linhas=1');
select pg_temp.e6_conferir('2 GHEs com cargos e inexistência de riscos',
  format($q$select count(*) from public.ghes where pcmso_id = %L
            and ((codigo = 'GHE-01' and cargos = '{Carpinteiro,Armador}' and status_matriz = 'valida'
                  and not aso_inexistencia_riscos)
              or (codigo = 'GHE-02' and cargos = '{Almoxarife}' and aso_inexistencia_riscos))$q$,
         pg_temp.e6_pcmso('m1')), 'linhas=2');
select pg_temp.e6_conferir('momentos mapeados para os tipos de exame da NR-7',
  $q$select count(*) from public.pcmso_exames x join public.ghes g on g.id = x.ghe_id
     where g.codigo = 'GHE-01' and x.exame = 'exame_clinico' and x.periodicidade_meses = 12
       and x.momentos = '{admissional,periodico,mudanca_de_risco,retorno_ao_trabalho,demissional}'
       and g.empresa_id = (select id from e6_fx where chave = 'emp_A')$q$, 'linhas=1');
select pg_temp.e6_conferir('periodicidade 0 e periodicidade após 15 anos aceitas',
  $q$select count(*) from public.pcmso_exames
     where exame = 'rx_torax' and periodicidade_meses = 0 and periodicidade_apos_15a = 12
       and empresa_id = (select id from e6_fx where chave = 'emp_A')$q$, 'linhas=1');
select pg_temp.e6_conferir('riscos do ASO com veredito sugerido',
  $q$select count(*) from public.ghe_riscos_aso
     where empresa_id = (select id from e6_fx where chave = 'emp_A')
       and ((risco = 'ruido' and reconhecido and veredito = 'consta' and exames = '{audiometria}')
         or (risco = 'POEIRA DE OBRA' and not reconhecido and veredito = 'conferir'))$q$, 'linhas=2');

select pg_temp.e6_caso('reenvio devolve ja_existia', 'a_med',
  pg_temp.e6_situacao(pg_temp.e6_envio('A', pg_temp.e6_matriz('m1', 'pdf-1')), 'ja_existia'), 'linhas=1');
select pg_temp.e6_caso('reenvio por outro papel também devolve ja_existia', 'a_tec',
  pg_temp.e6_situacao(pg_temp.e6_envio('A', pg_temp.e6_matriz('m1', 'pdf-1')), 'ja_existia'), 'linhas=1');
select pg_temp.e6_caso('cliente não envia nem matriz que já existe', 'a_cli',
  pg_temp.e6_situacao(pg_temp.e6_envio('A', pg_temp.e6_matriz('m1', 'pdf-1')), 'ja_existia'), 'erro=42501');

-- Segunda versão da matriz para o mesmo PGR (mesmo PDF): reusa o PGR.
select pg_temp.e6_gravar('a_tec', 'select ' || pg_temp.e6_envio('A', pg_temp.e6_matriz('m2', 'pdf-1')));
-- Terceira, PRELIMINAR, outro PDF.
select pg_temp.e6_gravar('a_med', 'select ' || pg_temp.e6_envio('A', pg_temp.e6_matriz('m3', 'pdf-3', 'PRELIMINAR')));
-- Mesma chave em B.
select pg_temp.e6_gravar('duplo_tec', 'select ' || pg_temp.e6_envio('B', pg_temp.e6_matriz('m1', 'pdf-1')));

select pg_temp.e6_conferir('reenvio e 2ª versão não duplicam o PGR',
  format($q$select count(*) from public.pgrs where empresa_id = %L and origem_externa_id = 'pdf-1'$q$,
         pg_temp.e6_fx('emp_A')), 'linhas=1');
select pg_temp.e6_conferir('3 PCMSOs em A (m1, m2, m3) e 1 em B',
  $q$select count(*) from public.pcmsos p join e6_fx f on f.id = p.empresa_id and f.chave in ('emp_A', 'emp_B')$q$,
  'linhas=4');
select pg_temp.e6_conferir('reenvio não duplica GHE',
  format($q$select count(*) from public.ghes where pcmso_id = %L$q$, pg_temp.e6_pcmso('m1')), 'linhas=2');

-- ---------------------------------------------------------------------------
-- 4. Ciclo de vida do PCMSO: só o médico; rascunho → vigente → substituido
-- ---------------------------------------------------------------------------
select pg_temp.e6_caso('técnico não altera PCMSO', 'a_tec',
  pg_temp.e6_upd('pcmsos', $s$observacoes = 'x'$s$, format('id = %L', pg_temp.e6_pcmso('m1'))), 'linhas=0');
select pg_temp.e6_caso('admin não altera PCMSO', 'a_admin',
  pg_temp.e6_upd('pcmsos', $s$observacoes = 'x'$s$, format('id = %L', pg_temp.e6_pcmso('m1'))), 'linhas=0');
select pg_temp.e6_caso('vigente sem médico responsável é recusado', 'a_med',
  pg_temp.e6_upd('pcmsos', $s$status = 'vigente'$s$, format('id = %L', pg_temp.e6_pcmso('m1'))), 'erro=23514');
select pg_temp.e6_caso('PRELIMINAR não vira vigente', 'a_med',
  pg_temp.e6_upd('pcmsos',
    $s$status = 'vigente', medico_responsavel_nome = 'Dra. Teste', medico_responsavel_crm = 'CRM-DF 1', vigente_desde = '2026-10-13'$s$,
    format('id = %L', pg_temp.e6_pcmso('m3'))), 'erro=23514');
select pg_temp.e6_caso('origem do PCMSO não muda', 'a_med',
  pg_temp.e6_upd('pcmsos', $s$versao_motor = 'outra'$s$, format('id = %L', pg_temp.e6_pcmso('m1'))), 'erro=KJ004');

select pg_temp.e6_gravar('a_med', format(
  $q$update public.pcmsos set status = 'vigente', medico_responsavel_nome = 'Dra. Teste',
       medico_responsavel_crm = 'CRM-DF 1', vigente_desde = '2026-10-13' where id = %L$q$, pg_temp.e6_pcmso('m1')));
select pg_temp.e6_conferir('PCMSO vigente com médico responsável e autoria',
  format($q$select count(*) from public.pcmsos where id = %L and status = 'vigente' and updated_by = %L$q$,
         pg_temp.e6_pcmso('m1'), pg_temp.e6_fx('u_a_med')), 'linhas=1');

select pg_temp.e6_caso('vigente não volta a rascunho', 'a_med',
  pg_temp.e6_upd('pcmsos', $s$status = 'rascunho'$s$, format('id = %L', pg_temp.e6_pcmso('m1'))), 'erro=KJ004');
select pg_temp.e6_caso('dois PCMSOs vigentes no mesmo PGR são recusados', 'a_med',
  pg_temp.e6_upd('pcmsos',
    $s$status = 'vigente', medico_responsavel_nome = 'Dra. Teste', medico_responsavel_crm = 'CRM-DF 1', vigente_desde = '2026-10-14'$s$,
    format('id = %L', pg_temp.e6_pcmso('m2'))), 'erro=23505');
select pg_temp.e6_caso('vigente pode ser substituído', 'a_med',
  pg_temp.e6_upd('pcmsos', $s$status = 'substituido'$s$, format('id = %L', pg_temp.e6_pcmso('m1'))), 'linhas=1');
select pg_temp.e6_caso('reenvio de PCMSO vigente devolve ja_existia sem mexer', 'a_med',
  format($q$select count(*) from (select %s r) x
            join public.pcmsos p on p.id = (x.r->>'pcmso_id')::uuid and p.status = 'vigente'
            where x.r->>'situacao' = 'ja_existia'$q$,
         pg_temp.e6_envio('A', pg_temp.e6_matriz('m1', 'pdf-1'))), 'linhas=1');

-- ---------------------------------------------------------------------------
-- 5. Matriz imutável fora do rascunho; sem UPDATE/DELETE
-- ---------------------------------------------------------------------------
select pg_temp.e6_caso('exame novo em PCMSO vigente é recusado', 'a_med',
  format($q$with i as (insert into public.pcmso_exames (empresa_id, ghe_id, exame, periodicidade_meses)
            select empresa_id, id, 'novo', 6 from public.ghes where pcmso_id = %L and codigo = 'GHE-01'
            returning 1) select count(*) from i$q$, pg_temp.e6_pcmso('m1')), 'erro=KJ004');
select pg_temp.e6_caso('GHE novo em PCMSO vigente é recusado', 'a_tec',
  format($q$with i as (insert into public.ghes (empresa_id, pcmso_id, codigo, nome, status_matriz)
            values (%L, %L, 'GHE-99', 'novo', 'valida') returning 1) select count(*) from i$q$,
         pg_temp.e6_fx('emp_A'), pg_temp.e6_pcmso('m1')), 'erro=KJ004');
select pg_temp.e6_caso('risco novo em PCMSO vigente é recusado', 'a_med',
  format($q$with i as (insert into public.ghe_riscos_aso (empresa_id, ghe_id, risco, reconhecido, veredito)
            select empresa_id, id, 'calor', true, 'consta' from public.ghes where pcmso_id = %L and codigo = 'GHE-01'
            returning 1) select count(*) from i$q$, pg_temp.e6_pcmso('m1')), 'erro=KJ004');
select pg_temp.e6_caso('exame novo em PCMSO em rascunho é aceito', 'a_tec',
  format($q$with i as (insert into public.pcmso_exames (empresa_id, ghe_id, exame, periodicidade_meses)
            select empresa_id, id, 'novo', 6 from public.ghes where pcmso_id = %L and codigo = 'GHE-01'
            returning 1) select count(*) from i$q$, pg_temp.e6_pcmso('m2')), 'linhas=1');
select pg_temp.e6_caso('ninguém altera exame (sem UPDATE)', 'a_med',
  pg_temp.e6_upd('pcmso_exames', 'periodicidade_meses = 6', 'true'), 'erro=42501');
select pg_temp.e6_caso('ninguém altera GHE (sem UPDATE)', 'a_admin',
  pg_temp.e6_upd('ghes', $s$nome = 'x'$s$, 'true'), 'erro=42501');
select pg_temp.e6_caso('sem exclusão física de PCMSO', 'a_med',
  'with d as (delete from public.pcmsos returning 1) select count(*) from d', 'erro=42501');
select pg_temp.e6_caso('sem exclusão física de GHE', 'a_admin',
  'with d as (delete from public.ghes returning 1) select count(*) from d', 'erro=42501');
select pg_temp.e6_caso('sem exclusão física de exame', 'a_med',
  'with d as (delete from public.pcmso_exames returning 1) select count(*) from d', 'erro=42501');
select pg_temp.e6_caso('sem exclusão física de risco do ASO', 'a_tec',
  'with d as (delete from public.ghe_riscos_aso returning 1) select count(*) from d', 'erro=42501');

-- ---------------------------------------------------------------------------
-- 6. Leitura e isolamento
-- ---------------------------------------------------------------------------
select pg_temp.e6_caso('cliente lê os PCMSOs da própria empresa', 'a_cli',
  'select count(*) from public.pcmsos', 'linhas=3');
select pg_temp.e6_caso('cliente lê os GHEs da própria empresa', 'a_cli',
  'select count(*) from public.ghes', 'linhas=6');
select pg_temp.e6_caso('cliente não insere GHE direto', 'a_cli',
  format($q$with i as (insert into public.ghes (empresa_id, pcmso_id, codigo, nome, status_matriz)
            values (%L, %L, 'GHE-98', 'x', 'valida') returning 1) select count(*) from i$q$,
         pg_temp.e6_fx('emp_A'), pg_temp.e6_pcmso('m2')), 'erro=42501');
select pg_temp.e6_caso('B não lê PCMSO de A', 'b_tec',
  format('select count(*) from public.pcmsos where empresa_id = %L', pg_temp.e6_fx('emp_A')), 'linhas=0');
select pg_temp.e6_caso('B não lê GHE de A', 'b_tec',
  format('select count(*) from public.ghes where empresa_id = %L', pg_temp.e6_fx('emp_A')), 'linhas=0');
select pg_temp.e6_caso('B não lê exame de A', 'b_tec',
  format('select count(*) from public.pcmso_exames where empresa_id = %L', pg_temp.e6_fx('emp_A')), 'linhas=0');
select pg_temp.e6_caso('B não lê risco do ASO de A', 'b_tec',
  format('select count(*) from public.ghe_riscos_aso where empresa_id = %L', pg_temp.e6_fx('emp_A')), 'linhas=0');
select pg_temp.e6_caso('B não insere GHE em PCMSO de A', 'b_tec',
  format($q$with i as (insert into public.ghes (empresa_id, pcmso_id, codigo, nome, status_matriz)
            values (%L, %L, 'GHE-97', 'x', 'valida') returning 1) select count(*) from i$q$,
         pg_temp.e6_fx('emp_A'), pg_temp.e6_pcmso('m2')), 'erro=42501');
select pg_temp.e6_caso('anon não lê PCMSO', 'anon', 'select count(*) from public.pcmsos', 'erro=42501');
select pg_temp.e6_caso('anon não lê GHE', 'anon', 'select count(*) from public.ghes', 'erro=42501');

-- ---------------------------------------------------------------------------
-- 7. PGR: o médico só cria em rascunho e não altera
-- ---------------------------------------------------------------------------
select pg_temp.e6_caso('médico não cria PGR vigente', 'a_med',
  format($q$with i as (insert into public.pgrs (empresa_id, versao, data_elaboracao, status)
            values (%L, 'X', current_date, 'vigente') returning 1) select count(*) from i$q$,
         pg_temp.e6_fx('emp_A')), 'erro=42501');
select pg_temp.e6_caso('médico não altera PGR', 'a_med',
  pg_temp.e6_upd('pgrs', $s$status = 'vigente'$s$, format('empresa_id = %L', pg_temp.e6_fx('emp_A'))), 'linhas=0');

-- ---------------------------------------------------------------------------
-- 8. Trabalhador → GHE
-- ---------------------------------------------------------------------------
select pg_temp.e6_caso('técnico vincula trabalhador a GHE da própria empresa', 'a_tec',
  pg_temp.e6_upd('trabalhadores',
    format($s$ghe_id = (select id from public.ghes where pcmso_id = %L and codigo = 'GHE-01')$s$, pg_temp.e6_pcmso('m1')),
    format('id = %L', pg_temp.e6_fx('trab_A'))), 'linhas=1');
select pg_temp.e6_caso('GHE de B não entra em trabalhador de A (FK composta)', 'duplo_tec',
  pg_temp.e6_upd('trabalhadores',
    format($s$ghe_id = (select g.id from public.ghes g where g.empresa_id = %L limit 1)$s$, pg_temp.e6_fx('emp_B')),
    format('id = %L', pg_temp.e6_fx('trab_A'))), 'erro=23503');
select pg_temp.e6_caso('médico não vincula trabalhador (não escreve trabalhadores)', 'a_med',
  pg_temp.e6_upd('trabalhadores',
    format($s$ghe_id = (select id from public.ghes where pcmso_id = %L and codigo = 'GHE-01')$s$, pg_temp.e6_pcmso('m1')),
    format('id = %L', pg_temp.e6_fx('trab_A'))), 'linhas=0');

-- ---------------------------------------------------------------------------
-- Asserções
-- ---------------------------------------------------------------------------
select plan((select count(*)::int + 4 from e6_casos));

select is((select count(*)::int from e6_casos), 7 + 13 + 6 + 3 + 3 + 5 + 1 + 4 + 10 + 10 + 2 + 3, 'quantidade de e6_casos gerados');

select is(
  (select prosecdef from pg_proc where oid = 'public.enviar_matriz_pcmso(uuid, uuid, jsonb)'::regprocedure),
  false, 'enviar_matriz_pcmso é SECURITY INVOKER (RLS do usuário vale)');
select is(
  (select proconfig @> array['search_path=""'] from pg_proc
    where oid = 'public.enviar_matriz_pcmso(uuid, uuid, jsonb)'::regprocedure),
  true, 'enviar_matriz_pcmso fixa search_path vazio');
select is(
  has_function_privilege('anon', 'public.enviar_matriz_pcmso(uuid, uuid, jsonb)', 'execute'),
  false, 'anon sem EXECUTE em enviar_matriz_pcmso');

select is(obtido, esperado, descricao) from e6_casos order by ordem;

select * from finish();
rollback;
