-- Emula, num Postgres puro, o mínimo que o Supabase fornece e que as migrations usam.
-- SÓ PARA TESTE LOCAL sem Docker. Não aplicar em projeto Supabase.
-- Fiel ao Supabase nos pontos que afetam a RLS:
--   * papéis anon / authenticated / service_role (este com BYPASSRLS);
--   * auth.uid() lendo o claim "sub" de request.jwt.claims (como o PostgREST injeta);
--   * default privileges que concedem ALL em public a anon e authenticated;
--   * storage.objects com RLS ligada e storage.foldername().

-- Papéis são do cluster, não do banco: sobrevivem ao drop database do run.sh.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end;
$$;

create schema auth;
create schema storage;
create schema extensions;

create table auth.users (
  id          uuid primary key,
  email       text,
  created_at  timestamptz not null default now()
);

create function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(
    coalesce(
      current_setting('request.jwt.claim.sub', true),
      current_setting('request.jwt.claims', true)::jsonb ->> 'sub'
    ),
    ''
  )::uuid
$$;

create function auth.role()
returns text
language sql
stable
as $$
  select nullif(
    coalesce(
      current_setting('request.jwt.claim.role', true),
      current_setting('request.jwt.claims', true)::jsonb ->> 'role'
    ),
    ''
  )::text
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on all functions in schema auth to anon, authenticated, service_role;

create table storage.buckets (
  id          text primary key,
  name        text not null,
  public      boolean not null default false,
  created_at  timestamptz not null default now()
);

create table storage.objects (
  id          uuid primary key default gen_random_uuid(),
  bucket_id   text references storage.buckets (id),
  name        text,
  owner       uuid,
  created_at  timestamptz not null default now(),
  unique (bucket_id, name)
);
alter table storage.objects enable row level security;
alter table storage.buckets enable row level security;

-- Cópia de storage.protect_delete medida no Supabase real em 05/10/2026: DELETE direto por
-- SQL é bloqueado; a API de Storage liga storage.allow_delete_query antes de excluir.
-- Gatilho por instrução (FOR EACH STATEMENT) inferido do RETURN NULL: numa versão por linha,
-- nenhuma exclusão aconteceria nem com a flag ligada. Confirmado pelos testes no Supabase.
create function storage.protect_delete()
returns trigger
language plpgsql
as $$
begin
  if coalesce(current_setting('storage.allow_delete_query', true), 'false') != 'true' then
    raise exception 'Direct deletion from storage tables is not allowed. Use the Storage API instead.'
      using hint = 'This prevents accidental data loss from orphaned objects.',
            errcode = '42501';
  end if;
  return null;
end;
$$;

create trigger protect_objects_delete
  before delete on storage.objects
  for each statement execute function storage.protect_delete();

create function storage.foldername(name text)
returns text[]
language plpgsql
immutable
as $$
declare
  _parts text[];
begin
  select string_to_array(name, '/') into _parts;
  return _parts[1:array_length(_parts, 1) - 1];
end;
$$;

grant usage on schema storage to anon, authenticated, service_role;
grant all on all tables in schema storage to anon, authenticated, service_role;
grant execute on all functions in schema storage to anon, authenticated, service_role;

grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables    to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

create extension pgtap with schema extensions;
grant usage on schema extensions to anon, authenticated, service_role;
