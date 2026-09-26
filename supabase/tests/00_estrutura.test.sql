-- Metatestes sobre o catálogo: pegam esquecimentos em tabelas criadas no futuro.
begin;
create extension if not exists pgtap with schema extensions;

select plan(8);

select is(
  array(
    select c.relname::text from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity
    order by 1
  ),
  '{}'::text[],
  'toda tabela em public tem RLS ligada'
);

select is(
  array(
    select c.relname::text from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and c.relname <> 'empresas'
      and not exists (
        select 1 from pg_attribute a
        where a.attrelid = c.oid and a.attname = 'empresa_id' and a.attnotnull and not a.attisdropped
      )
    order by 1
  ),
  '{}'::text[],
  'toda tabela em public (exceto empresas) tem empresa_id NOT NULL'
);

select is(
  array(
    select format('%s.%s.%s', table_schema, table_name, column_name)
    from information_schema.columns
    where table_schema in ('public', 'storage')
      and column_name ~* '(^|_)(cid|cid10|cid_10|diagnostico|diagnóstico|hipotese_diagnostica)($|_)'
    order by 1
  ),
  '{}'::text[],
  'nenhuma coluna de CID/diagnóstico em schema exposto (NR-7; LGPD art. 11)'
);

select is(
  array(
    select c.relname::text from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm')
      and (has_table_privilege('anon', c.oid, 'select')
        or has_table_privilege('anon', c.oid, 'insert')
        or has_table_privilege('anon', c.oid, 'update')
        or has_table_privilege('anon', c.oid, 'delete'))
    order by 1
  ),
  '{}'::text[],
  'anon não tem privilégio em nenhuma tabela de public'
);

select is(
  array(
    select c.relname::text from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and has_table_privilege('authenticated', c.oid, 'truncate')
    order by 1
  ),
  '{}'::text[],
  'authenticated não tem TRUNCATE (TRUNCATE ignora RLS)'
);

select is(
  array(
    select c.relname::text from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and c.relname <> 'membros'
      and has_table_privilege('authenticated', c.oid, 'delete')
    order by 1
  ),
  '{}'::text[],
  'exclusão física só em membros'
);

select is(
  array(
    select c.relname::text from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and not exists (
        select 1 from pg_trigger t
        where t.tgrelid = c.oid and t.tgname = 'carimbar' and not t.tgisinternal
      )
    order by 1
  ),
  '{}'::text[],
  'toda tabela em public tem o trigger carimbar (trava troca de empresa_id)'
);

select is(
  array(
    select p.proname::text from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private' and p.prosecdef
      and not coalesce(p.proconfig @> array['search_path=""'], false)
    order by 1
  ),
  '{}'::text[],
  'toda função SECURITY DEFINER em private fixa search_path vazio'
);

select * from finish();
rollback;
