-- KAIJU SGI — esquema multi-tenant base (etapa 0.2)
--
-- Regras estruturais:
--   * toda tabela de negócio tem empresa_id NOT NULL;
--   * FKs entre tabelas de negócio usam o par (empresa_id, id), de modo que uma linha
--     da empresa A nunca referencia linha da empresa B — nem se a RLS tiver falha
--     (checagem de FK roda como dono da tabela e ignora RLS);
--   * nenhuma coluna de CID/diagnóstico (NR-7; LGPD art. 11). Dado clínico, se um dia
--     existir, vai para schema não exposto na API;
--   * sem exclusão física em registros de histórico: encerra-se por status/ativo.

create schema if not exists private;

-- ---------------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------------
create type public.papel as enum ('admin', 'tecnico_sst', 'medico', 'cliente_leitura');
create type public.tipo_estabelecimento as enum ('estabelecimento', 'obra');
create type public.status_pgr as enum ('rascunho', 'vigente', 'substituido');
create type public.origem_nc as enum ('auditoria_nr', 'inspecao', 'auditoria_iso', 'incidente', 'outro');
create type public.severidade as enum ('baixa', 'media', 'alta', 'critica');
create type public.status_nc as enum ('aberta', 'em_tratamento', 'encerrada', 'cancelada');
create type public.status_acao as enum ('pendente', 'em_andamento', 'concluida', 'cancelada');
-- Tipos de exame do PCMSO (NR-7). Conferir itens no texto vigente em Gov.br/MTE.
create type public.tipo_aso as enum (
  'admissional', 'periodico', 'retorno_ao_trabalho', 'mudanca_de_risco', 'demissional'
);
create type public.resultado_aso as enum ('apto', 'inapto');

-- ---------------------------------------------------------------------------
-- Carimbo de autoria + trava de troca de empresa
-- ---------------------------------------------------------------------------
create function private.carimbar()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.created_by := auth.uid();
  else
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    -- Com RLS, um usuário com escrita em A e em B passaria no WITH CHECK ao mover a linha.
    -- Aninhado: "empresas" não tem empresa_id e o AND do PL/pgSQL não garante curto-circuito.
    if tg_table_name <> 'empresas' then
      if new.empresa_id is distinct from old.empresa_id then
        raise exception 'empresa_id não pode ser alterado (%.%)', tg_table_schema, tg_table_name
          using errcode = 'KJ002';
      end if;
    end if;
  end if;
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Tenant e vínculo usuário × empresa × papel
-- ---------------------------------------------------------------------------
create table public.empresas (
  id            uuid primary key default gen_random_uuid(),
  razao_social  text not null,
  cnpj          text not null unique check (cnpj ~ '^[0-9]{14}$'),
  cnae          text,
  grau_risco    smallint check (grau_risco between 1 and 4),  -- NR-4, Anexo I
  ativo         boolean not null default true,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid
);

create table public.membros (
  usuario_id  uuid not null references auth.users (id) on delete cascade,
  empresa_id  uuid not null references public.empresas (id) on delete restrict,
  papel       public.papel not null,
  ativo       boolean not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  primary key (usuario_id, empresa_id)
);
create index membros_empresa_idx on public.membros (empresa_id);

-- ---------------------------------------------------------------------------
-- Cadastros
-- ---------------------------------------------------------------------------
create table public.estabelecimentos (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null references public.empresas (id) on delete restrict,
  tipo        public.tipo_estabelecimento not null,
  nome        text not null,
  cnpj        text check (cnpj ~ '^[0-9]{14}$'),
  cno         text check (cno ~ '^[0-9]{12}$'),  -- Cadastro Nacional de Obras
  endereco    text,
  ativo       boolean not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  unique (empresa_id, id)
);

create table public.trabalhadores (
  id                  uuid primary key default gen_random_uuid(),
  empresa_id          uuid not null references public.empresas (id) on delete restrict,
  estabelecimento_id  uuid,
  nome                text not null,
  cpf                 text not null check (cpf ~ '^[0-9]{11}$'),
  matricula           text,
  funcao              text,
  data_admissao       date,
  data_desligamento   date check (data_desligamento is null or data_desligamento >= data_admissao),
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  unique (empresa_id, id),
  unique (empresa_id, cpf),
  foreign key (empresa_id, estabelecimento_id) references public.estabelecimentos (empresa_id, id)
);

-- ---------------------------------------------------------------------------
-- PGR (NR-1, item 1.5)
-- ---------------------------------------------------------------------------
create table public.pgrs (
  id                     uuid primary key default gen_random_uuid(),
  empresa_id             uuid not null references public.empresas (id) on delete restrict,
  estabelecimento_id     uuid,
  versao                 text not null,
  data_elaboracao        date not null,
  data_revisao_prevista  date check (data_revisao_prevista is null or data_revisao_prevista >= data_elaboracao),
  responsavel_tecnico    text,
  status                 public.status_pgr not null default 'rascunho',
  arquivo_path           text,  -- caminho no bucket "documentos"
  observacoes            text,
  created_at             timestamptz not null default now(),
  created_by             uuid,
  updated_at             timestamptz not null default now(),
  updated_by             uuid,
  unique (empresa_id, id),
  foreign key (empresa_id, estabelecimento_id) references public.estabelecimentos (empresa_id, id)
);

-- ---------------------------------------------------------------------------
-- Não conformidades e ações
-- ---------------------------------------------------------------------------
create table public.nao_conformidades (
  id                  uuid primary key default gen_random_uuid(),
  empresa_id          uuid not null references public.empresas (id) on delete restrict,
  estabelecimento_id  uuid,
  origem              public.origem_nc not null,
  -- Id no app de origem (ex.: app-auditoria-nrs); torna o "Enviar para o Kaiju" idempotente.
  origem_externa_id   text,
  norma_ref           text,  -- ex.: 'NR-12'
  item_ref            text,  -- ex.: '12.5.1'
  descricao           text not null,
  severidade          public.severidade,
  status              public.status_nc not null default 'aberta',
  data_identificacao  date not null default current_date,
  evidencias          text[] not null default '{}',  -- caminhos no bucket "documentos"
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  unique (empresa_id, id),
  unique (empresa_id, origem, origem_externa_id),
  foreign key (empresa_id, estabelecimento_id) references public.estabelecimentos (empresa_id, id)
);

create table public.acoes (
  id                   uuid primary key default gen_random_uuid(),
  empresa_id           uuid not null references public.empresas (id) on delete restrict,
  nc_id                uuid,
  pgr_id               uuid,
  descricao            text not null,
  responsavel          text,
  prazo                date,
  status               public.status_acao not null default 'pendente',
  concluida_em         date,
  eficacia_verificada  boolean not null default false,
  eficacia_obs         text,
  created_at           timestamptz not null default now(),
  created_by           uuid,
  updated_at           timestamptz not null default now(),
  updated_by           uuid,
  unique (empresa_id, id),
  check ((status = 'concluida') = (concluida_em is not null)),
  foreign key (empresa_id, nc_id)  references public.nao_conformidades (empresa_id, id),
  foreign key (empresa_id, pgr_id) references public.pgrs (empresa_id, id)
);

-- ---------------------------------------------------------------------------
-- Treinamentos
-- ---------------------------------------------------------------------------
create table public.treinamentos (
  id              uuid primary key default gen_random_uuid(),
  empresa_id      uuid not null references public.empresas (id) on delete restrict,
  nome            text not null,
  nr_ref          text,  -- ex.: 'NR-35'
  carga_horaria_h numeric(6, 2) check (carga_horaria_h > 0),
  validade_meses  integer check (validade_meses > 0),
  ativo           boolean not null default true,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  unique (empresa_id, id)
);

create table public.treinamentos_realizados (
  id               uuid primary key default gen_random_uuid(),
  empresa_id       uuid not null references public.empresas (id) on delete restrict,
  trabalhador_id   uuid not null,
  treinamento_id   uuid not null,
  data_realizacao  date not null,
  valido_ate       date check (valido_ate is null or valido_ate >= data_realizacao),
  instrutor        text,
  certificado_path text,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  unique (empresa_id, id),
  foreign key (empresa_id, trabalhador_id) references public.trabalhadores (empresa_id, id),
  foreign key (empresa_id, treinamento_id) references public.treinamentos (empresa_id, id)
);

-- ---------------------------------------------------------------------------
-- ASO — sem CID/diagnóstico (NR-7)
-- ---------------------------------------------------------------------------
create table public.asos (
  id              uuid primary key default gen_random_uuid(),
  empresa_id      uuid not null references public.empresas (id) on delete restrict,
  trabalhador_id  uuid not null,
  tipo            public.tipo_aso not null,
  data_exame      date not null,
  resultado       public.resultado_aso not null,
  medico_nome     text not null,
  medico_crm      text not null,
  proximo_exame   date check (proximo_exame is null or proximo_exame >= data_exame),
  arquivo_path    text,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  unique (empresa_id, id),
  foreign key (empresa_id, trabalhador_id) references public.trabalhadores (empresa_id, id)
);

-- Índices para as consultas de vencimento e de listagem por empresa
create index trabalhadores_estab_idx      on public.trabalhadores (empresa_id, estabelecimento_id);
create index nc_status_idx                on public.nao_conformidades (empresa_id, status);
create index acoes_prazo_idx              on public.acoes (empresa_id, status, prazo);
create index acoes_nc_idx                 on public.acoes (empresa_id, nc_id);
create index trein_real_validade_idx      on public.treinamentos_realizados (empresa_id, valido_ate);
create index trein_real_trab_idx          on public.treinamentos_realizados (empresa_id, trabalhador_id);
create index asos_proximo_idx             on public.asos (empresa_id, proximo_exame);
create index asos_trab_idx                on public.asos (empresa_id, trabalhador_id);

-- Carimbo em todas as tabelas de public
do $$
declare
  t text;
begin
  foreach t in array array[
    'empresas', 'membros', 'estabelecimentos', 'trabalhadores', 'pgrs',
    'nao_conformidades', 'acoes', 'treinamentos', 'treinamentos_realizados', 'asos'
  ] loop
    execute format(
      'create trigger carimbar before insert or update on public.%I
         for each row execute function private.carimbar()', t);
  end loop;
end;
$$;
