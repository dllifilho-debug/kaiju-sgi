-- KAIJU SGI — bucket privado de documentos (etapa 0.2)
-- Caminho obrigatório: {empresa_id}/... — a primeira pasta define o tenant.
-- Comparação como texto: um cast ::uuid num caminho inválido lançaria erro em vez de negar.

insert into storage.buckets (id, name, public)
values ('documentos', 'documentos', false)
on conflict (id) do nothing;

create policy documentos_select on storage.objects for select to authenticated
  using (
    bucket_id = 'documentos'
    and (storage.foldername(name))[1] in (select id::text from private.empresas_do_usuario() as id)
  );

create policy documentos_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'documentos'
    and (storage.foldername(name))[1] in (
      select id::text from private.empresas_com_papel('{admin,tecnico_sst,medico}') as id)
  );

create policy documentos_update on storage.objects for update to authenticated
  using (
    bucket_id = 'documentos'
    and (storage.foldername(name))[1] in (
      select id::text from private.empresas_com_papel('{admin,tecnico_sst,medico}') as id)
  )
  with check (
    bucket_id = 'documentos'
    and (storage.foldername(name))[1] in (
      select id::text from private.empresas_com_papel('{admin,tecnico_sst,medico}') as id)
  );

create policy documentos_delete on storage.objects for delete to authenticated
  using (
    bucket_id = 'documentos'
    and (storage.foldername(name))[1] in (select id::text from private.empresas_com_papel('{admin}') as id)
  );
