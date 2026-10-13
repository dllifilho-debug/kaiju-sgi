-- KAIJU SGI — matriz de exames do PCMSO por GHE (etapa 2a)            *** PROPOSTA — NÃO APLICAR ***
--
-- Origem: app automacao-pgr-agente-pcmso (agente_medico/motor/tipos.py: MatrizGHE, ExameEmitido,
-- RelatorioASO). O app gera a matriz a partir do PGR + FDS; o Kaiju guarda um RETRATO dela,
-- ligado ao PGR, para calcular o vencimento do ASO por trabalhador:
--   trabalhador → GHE → periodicidade do exame clínico → último ASO + periodicidade.
--
-- Modelo:
--   pgrs (existente) 1─n pcmsos 1─n ghes 1─n pcmso_exames
--                                       └─n ghe_riscos_aso   (NR-7 7.5.19.1 "c": sugestão do app)
--   trabalhadores.ghe_id (opcional) → ghes
--
-- Regras:
--   * PCMSO é documento próprio (NR-7), distinto do PGR (NR-1): chega como 'rascunho' e só o
--     médico o torna 'vigente', informando o médico responsável (NR-7 7.5.19.1 "f").
--   * A matriz é imutável: ghes/pcmso_exames/ghe_riscos_aso só recebem INSERT, e só enquanto o
--     PCMSO está em rascunho (trigger). Correção = novo envio, nova versão.
--   * Sem dado de saúde individual: nada aqui é do trabalhador, exceto o vínculo ao GHE.
--   * FKs compostas (empresa_id, id) como na 0.2; RLS por empresa; carimbo de autoria.
--   * Objetos existentes alterados: trabalhadores (+ghe_id), pgrs (+origem_externa_id e uma
--     política ADICIONAL de insert para o médico, só em rascunho). Nenhuma política existente muda.

-- ---------------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------------
create type public.status_pcmso as enum ('rascunho', 'vigente', 'substituido');
create type public.status_matriz_ghe as enum ('valida', 'parcial', 'bloqueada');  -- MatrizGHE.status
create type public.veredito_aso as enum ('consta', 'conferir', 'nao_consta');     -- VereditoASO

-- ---------------------------------------------------------------------------
-- PGR: chave de idempotência do envio (hash do PDF do PGR, calculado no app)
-- ---------------------------------------------------------------------------
alter table public.pgrs
  add column origem_externa_id text,
  add constraint pgrs_origem_externa_unica unique (empresa_id, origem_externa_id);

-- ---------------------------------------------------------------------------
-- PCMSO
-- ---------------------------------------------------------------------------
create table public.pcmsos (
  id                 uuid primary key default gen_random_uuid(),
  empresa_id         uuid not null references public.empresas (id) on delete restrict,
  pgr_id             uuid not null,
  status             public.status_pcmso not null default 'rascunho',
  -- Resultado.status do motor; 'REJEITADO' não é enviado.
  resultado_motor    text not null check (resultado_motor in ('OK', 'PRELIMINAR')),
  versao_motor       text,           -- commit do app que gerou a matriz (rastreabilidade)
  origem_externa_id  text not null,  -- chave do envio, definida pelo app
  medico_responsavel_nome  text,     -- NR-7 7.5.19.1 "f"
  medico_responsavel_crm   text,
  vigente_desde      date,
  observacoes        text,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  unique (empresa_id, id),
  unique (empresa_id, origem_externa_id),
  foreign key (empresa_id, pgr_id) references public.pgrs (empresa_id, id),
  constraint pcmso_vigente_completo check (
    status = 'rascunho'
    or (medico_responsavel_nome is not null and medico_responsavel_crm is not null
        and vigente_desde is not null)
  )
);
-- Um PCMSO vigente por PGR; a troca marca o anterior como 'substituido' antes.
create unique index pcmsos_um_vigente_por_pgr on public.pcmsos (empresa_id, pgr_id)
  where status = 'vigente';

-- ---------------------------------------------------------------------------
-- GHE (retrato do PGR no momento do envio)
-- ---------------------------------------------------------------------------
create table public.ghes (
  id               uuid primary key default gen_random_uuid(),
  empresa_id       uuid not null references public.empresas (id) on delete restrict,
  pcmso_id         uuid not null,
  codigo           text not null,   -- MatrizGHE.ghe_id (id do MAPA no app)
  nome             text not null,   -- MatrizGHE.nome_ghe
  cargos           text[] not null default '{}',  -- MatrizGHE.cargos, verbatim do PGR
  status_matriz    public.status_matriz_ghe not null,
  regime_aplicado  text,
  aso_inexistencia_riscos  boolean not null default false,  -- RelatorioASO.inexistencia (NR-7 7.5.19.1 "c")
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  unique (empresa_id, id),
  unique (empresa_id, pcmso_id, codigo),
  foreign key (empresa_id, pcmso_id) references public.pcmsos (empresa_id, id)
);

create table public.pcmso_exames (
  id                      uuid primary key default gen_random_uuid(),
  empresa_id              uuid not null references public.empresas (id) on delete restrict,
  ghe_id                  uuid not null,
  exame                   text not null,  -- slug do app ('exame_clinico', 'audiometria'...)
  -- 0 = sem repetição periódica (o motor emite 0, ex.: RX fora da janela).
  periodicidade_meses     integer not null check (periodicidade_meses >= 0),
  periodicidade_apos_15a  integer check (periodicidade_apos_15a >= 0),
  -- Momento → tipo de exame da NR-7 7.5.6: ADM/PER/MR/RT/DEM.
  momentos                public.tipo_aso[] not null default '{}',
  created_at              timestamptz not null default now(),
  created_by              uuid,
  updated_at              timestamptz not null default now(),
  updated_by              uuid,
  unique (empresa_id, id),
  unique (empresa_id, ghe_id, exame),
  foreign key (empresa_id, ghe_id) references public.ghes (empresa_id, id)
);

create table public.ghe_riscos_aso (
  id           uuid primary key default gen_random_uuid(),
  empresa_id   uuid not null references public.empresas (id) on delete restrict,
  ghe_id       uuid not null,
  risco        text not null,     -- slug do agente, ou termo do PGR se não reconhecido
  reconhecido  boolean not null,
  veredito     public.veredito_aso not null,  -- sugestão do app; decisão final é do médico
  exames       text[] not null default '{}',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  unique (empresa_id, id),
  unique (empresa_id, ghe_id, risco),
  foreign key (empresa_id, ghe_id) references public.ghes (empresa_id, id)
);

-- ---------------------------------------------------------------------------
-- Trabalhador → GHE (confirmado à mão na tela; sugestão pelo cargo fica no frontend)
-- ---------------------------------------------------------------------------
alter table public.trabalhadores
  add column ghe_id uuid,
  add constraint trabalhadores_ghe_fk
    foreign key (empresa_id, ghe_id) references public.ghes (empresa_id, id);

create index pcmsos_pgr_idx        on public.pcmsos (empresa_id, pgr_id);
create index ghes_pcmso_idx        on public.ghes (empresa_id, pcmso_id);
create index pcmso_exames_ghe_idx  on public.pcmso_exames (empresa_id, ghe_id);
create index ghe_riscos_aso_ghe_idx on public.ghe_riscos_aso (empresa_id, ghe_id);
create index trabalhadores_ghe_idx on public.trabalhadores (empresa_id, ghe_id);

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['pcmsos', 'ghes', 'pcmso_exames', 'ghe_riscos_aso'] loop
    execute format(
      'create trigger carimbar before insert or update on public.%I
         for each row execute function private.carimbar()', t);
  end loop;
end;
$$;

-- Matriz só cresce enquanto o PCMSO está em rascunho (inclusive por INSERT direto na API,
-- que a RLS permite a quem pode enviar).
create function private.matriz_so_em_rascunho()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status public.status_pcmso;
begin
  if tg_table_name = 'ghes' then
    select p.status into v_status from public.pcmsos p
    where p.empresa_id = new.empresa_id and p.id = new.pcmso_id;
  else
    select p.status into v_status
    from public.ghes g join public.pcmsos p on p.empresa_id = g.empresa_id and p.id = g.pcmso_id
    where g.empresa_id = new.empresa_id and g.id = new.ghe_id;
  end if;
  if v_status is distinct from 'rascunho' then
    raise exception 'matriz de PCMSO % não aceita alteração (status %)', tg_table_name, v_status
      using errcode = 'KJ004';
  end if;
  return new;
end;
$$;

do $$
declare
  t text;
begin
  foreach t in array array['ghes', 'pcmso_exames', 'ghe_riscos_aso'] loop
    execute format(
      'create trigger matriz_so_em_rascunho before insert on public.%I
         for each row execute function private.matriz_so_em_rascunho()', t);
  end loop;
end;
$$;

-- PCMSO: depois de sair do rascunho, só o status anda (vigente → substituido); o vínculo ao PGR
-- e a origem nunca mudam. Volta para rascunho não existe.
create function private.travar_pcmso()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.pgr_id is distinct from old.pgr_id
     or new.origem_externa_id is distinct from old.origem_externa_id
     or new.resultado_motor is distinct from old.resultado_motor
     or new.versao_motor is distinct from old.versao_motor then
    raise exception 'origem do PCMSO não pode ser alterada' using errcode = 'KJ004';
  end if;
  if not (old.status = new.status
          or (old.status = 'rascunho' and new.status = 'vigente')
          or (old.status = 'vigente' and new.status = 'substituido')) then
    raise exception 'transição de PCMSO inválida: % → %', old.status, new.status
      using errcode = 'KJ004';
  end if;
  return new;
end;
$$;

create trigger travar_pcmso
  before update on public.pcmsos
  for each row execute function private.travar_pcmso();

revoke all on function private.matriz_so_em_rascunho() from public, anon, authenticated;
revoke all on function private.travar_pcmso() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Privilégios e RLS
--   pcmsos ........................ todos L · admin/tecnico_sst/medico inserem · medico altera
--   ghes, pcmso_exames,
--   ghe_riscos_aso ................ todos L · admin/tecnico_sst/medico inserem · ninguém altera
--   pgrs (adicional) .............. medico insere, só em rascunho (para o envio criar o PGR)
-- ---------------------------------------------------------------------------
-- Tabela nova herda dos default privileges do Supabase ALL para anon e authenticated, inclusive
-- TRUNCATE (que ignora RLS). Zerar antes de conceder, como a 0002 fez com as tabelas dela.
revoke all on public.pcmsos, public.ghes, public.pcmso_exames, public.ghe_riscos_aso
  from anon, authenticated;
grant select, insert, update on public.pcmsos to authenticated;
grant select, insert on public.ghes, public.pcmso_exames, public.ghe_riscos_aso to authenticated;

alter table public.pcmsos         enable row level security;
alter table public.ghes           enable row level security;
alter table public.pcmso_exames   enable row level security;
alter table public.ghe_riscos_aso enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['pcmsos', 'ghes', 'pcmso_exames', 'ghe_riscos_aso'] loop
    execute format($f$
      create policy %1$s_select on public.%1$I for select to authenticated
        using (empresa_id in (select private.empresas_do_usuario()));
      create policy %1$s_insert on public.%1$I for insert to authenticated
        with check (empresa_id in (select private.empresas_com_papel('{admin,tecnico_sst,medico}')));
    $f$, t);
  end loop;
end;
$$;

create policy pcmsos_update on public.pcmsos for update to authenticated
  using      (empresa_id in (select private.empresas_com_papel('{medico}')))
  with check (empresa_id in (select private.empresas_com_papel('{medico}')));

create policy pgrs_insert_medico on public.pgrs for insert to authenticated
  with check (status = 'rascunho'
              and empresa_id in (select private.empresas_com_papel('{medico}')));

-- ---------------------------------------------------------------------------
-- RPC do "Enviar para o Kaiju" (app PCMSO)
--
-- p_matriz:
-- {
--   "origem_externa_id": "<chave do envio>",
--   "resultado_motor": "OK" | "PRELIMINAR",
--   "versao_motor": "<commit>",
--   "pgr": { "origem_externa_id": "<sha256 do PDF>", "versao": "...",
--            "data_elaboracao": "AAAA-MM-DD",   -- a "validade" confirmada na tela = data de emissão
--            "responsavel_tecnico": "..." },
--   "ghes": [ { "codigo": "...", "nome": "...", "cargos": ["..."],
--               "status": "VÁLIDA" | "PARCIAL" | "BLOQUEADA", "regime_aplicado": "...",
--               "aso_inexistencia_riscos": false,
--               "exames": [ { "exame": "exame_clinico", "periodicidade_meses": 12,
--                             "periodicidade_apos_15a": null,
--                             "momentos": ["ADM","PER","MR","RT","DEM"] } ],
--               "riscos_aso": [ { "risco": "ruido", "reconhecido": true,
--                                 "veredito": "CONSTA", "exames": ["audiometria"] } ] } ]
-- }
-- Atômica (qualquer item inválido desfaz tudo); idempotente: PCMSO com a mesma
-- origem_externa_id volta como 'ja_existia', sem alterar nada. PGR com o mesmo hash é reusado.
-- SECURITY INVOKER: RLS, papéis, FKs compostas, carimbo e triggers valem como num INSERT direto.
-- ---------------------------------------------------------------------------
create function public.enviar_matriz_pcmso(
  p_empresa_id          uuid,
  p_estabelecimento_id  uuid,
  p_matriz              jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_ref      text;
  v_pgr_ref  text;
  v_pgr      uuid;
  v_pcmso    uuid;
  v_ghe      uuid;
  g          jsonb;
  ex         jsonb;
  r          jsonb;
  v_codigo   text;
  v_momentos public.tipo_aso[];
  n_ghes     integer := 0;
begin
  if p_empresa_id is null then
    raise exception 'empresa não informada' using errcode = 'KJ003';
  end if;
  if jsonb_typeof(p_matriz) is distinct from 'object' then
    raise exception 'matriz deve ser um objeto' using errcode = 'KJ003';
  end if;
  v_ref := nullif(btrim(p_matriz ->> 'origem_externa_id'), '');
  if v_ref is null then
    raise exception 'matriz sem origem_externa_id' using errcode = 'KJ003';
  end if;
  v_pgr_ref := nullif(btrim(p_matriz #>> '{pgr,origem_externa_id}'), '');
  if v_pgr_ref is null then
    raise exception 'pgr sem origem_externa_id' using errcode = 'KJ003';
  end if;
  if jsonb_typeof(p_matriz -> 'ghes') is distinct from 'array'
     or jsonb_array_length(p_matriz -> 'ghes') = 0 then
    raise exception 'ghes deve ser uma lista não vazia' using errcode = 'KJ003';
  end if;
  if jsonb_array_length(p_matriz -> 'ghes') > 500 then
    raise exception 'matriz com mais de 500 GHEs' using errcode = 'KJ003';
  end if;

  -- Reenvio: nada muda.
  select p.id, p.pgr_id into v_pcmso, v_pgr
  from public.pcmsos p
  where p.empresa_id = p_empresa_id and p.origem_externa_id = v_ref;
  if v_pcmso is not null then
    return jsonb_build_object('pcmso_id', v_pcmso, 'pgr_id', v_pgr, 'situacao', 'ja_existia');
  end if;

  -- PGR: reusa pelo hash; senão cria em rascunho.
  select p.id into v_pgr from public.pgrs p
  where p.empresa_id = p_empresa_id and p.origem_externa_id = v_pgr_ref;
  if v_pgr is null then
    if nullif(btrim(p_matriz #>> '{pgr,versao}'), '') is null
       or p_matriz #>> '{pgr,data_elaboracao}' is null then
      raise exception 'pgr sem versao ou data_elaboracao' using errcode = 'KJ003';
    end if;
    insert into public.pgrs (
      empresa_id, estabelecimento_id, versao, data_elaboracao, responsavel_tecnico,
      status, origem_externa_id
    ) values (
      p_empresa_id, p_estabelecimento_id, p_matriz #>> '{pgr,versao}',
      (p_matriz #>> '{pgr,data_elaboracao}')::date, p_matriz #>> '{pgr,responsavel_tecnico}',
      'rascunho', v_pgr_ref
    )
    returning id into v_pgr;
  end if;

  insert into public.pcmsos (empresa_id, pgr_id, resultado_motor, versao_motor, origem_externa_id)
  values (p_empresa_id, v_pgr, p_matriz ->> 'resultado_motor', p_matriz ->> 'versao_motor', v_ref)
  returning id into v_pcmso;

  for g in select value from jsonb_array_elements(p_matriz -> 'ghes') loop
    v_codigo := nullif(btrim(g ->> 'codigo'), '');
    if v_codigo is null or nullif(btrim(g ->> 'nome'), '') is null then
      raise exception 'GHE sem codigo ou nome' using errcode = 'KJ003';
    end if;
    if jsonb_typeof(g -> 'exames') is distinct from 'array' then
      raise exception 'GHE % sem lista de exames', v_codigo using errcode = 'KJ003';
    end if;

    insert into public.ghes (
      empresa_id, pcmso_id, codigo, nome, cargos, status_matriz, regime_aplicado,
      aso_inexistencia_riscos
    ) values (
      p_empresa_id, v_pcmso, v_codigo, g ->> 'nome',
      coalesce(array(select jsonb_array_elements_text(g -> 'cargos')), '{}'),
      case g ->> 'status'
        when 'VÁLIDA' then 'valida' when 'PARCIAL' then 'parcial' when 'BLOQUEADA' then 'bloqueada'
      end::public.status_matriz_ghe,
      g ->> 'regime_aplicado',
      coalesce((g ->> 'aso_inexistencia_riscos')::boolean, false)
    )
    returning id into v_ghe;

    for ex in select value from jsonb_array_elements(g -> 'exames') loop
      if nullif(btrim(ex ->> 'exame'), '') is null then
        raise exception 'GHE % com exame sem nome', v_codigo using errcode = 'KJ003';
      end if;
      select coalesce(array_agg(case m
               when 'ADM' then 'admissional' when 'PER' then 'periodico'
               when 'MR'  then 'mudanca_de_risco' when 'RT' then 'retorno_ao_trabalho'
               when 'DEM' then 'demissional' end::public.tipo_aso), '{}')
        into v_momentos
      from jsonb_array_elements_text(coalesce(ex -> 'momentos', '[]')) as m;
      if array_position(v_momentos, null) is not null then
        raise exception 'GHE % exame %: momento desconhecido', v_codigo, ex ->> 'exame'
          using errcode = 'KJ003';
      end if;
      insert into public.pcmso_exames (
        empresa_id, ghe_id, exame, periodicidade_meses, periodicidade_apos_15a, momentos
      ) values (
        p_empresa_id, v_ghe, ex ->> 'exame', (ex ->> 'periodicidade_meses')::integer,
        (ex ->> 'periodicidade_apos_15a')::integer, v_momentos
      );
    end loop;

    for r in select value from jsonb_array_elements(coalesce(g -> 'riscos_aso', '[]')) loop
      insert into public.ghe_riscos_aso (empresa_id, ghe_id, risco, reconhecido, veredito, exames)
      values (
        p_empresa_id, v_ghe, r ->> 'risco', (r ->> 'reconhecido')::boolean,
        lower(r ->> 'veredito')::public.veredito_aso,
        coalesce(array(select jsonb_array_elements_text(r -> 'exames')), '{}')
      );
    end loop;
    n_ghes := n_ghes + 1;
  end loop;

  return jsonb_build_object('pcmso_id', v_pcmso, 'pgr_id', v_pgr, 'situacao', 'criada',
                            'ghes', n_ghes);
end;
$$;

revoke all on function public.enviar_matriz_pcmso(uuid, uuid, jsonb) from public, anon;
grant execute on function public.enviar_matriz_pcmso(uuid, uuid, jsonb) to authenticated;
