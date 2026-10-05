-- KAIJU SGI — campos de tratamento de NC e de ação usados pelo frontend (etapa 0.3)
-- Aprovado pelo dono em 05/10/2026. Colunas opcionais: integrações (ex.: app-auditoria-nrs)
-- continuam podendo gravar só os campos obrigatórios da 0.2.
-- RLS e privilégios não mudam: as políticas da 0.2 valem por linha, para qualquer coluna.

create type public.tipo_acao as enum ('corretiva', 'preventiva', 'melhoria');

alter table public.nao_conformidades
  add column titulo       text,
  add column setor        text,
  add column responsavel  text,
  add column prazo        date,
  add constraint nc_prazo_valido check (prazo is null or prazo >= data_identificacao);

alter table public.acoes
  add column titulo      text,
  add column tipo        public.tipo_acao,
  add column prioridade  public.severidade,
  add column setor       text,
  add column progresso   smallint not null default 0,
  add constraint acoes_progresso_valido check (progresso between 0 and 100);

create index nc_prazo_idx on public.nao_conformidades (empresa_id, prazo);
