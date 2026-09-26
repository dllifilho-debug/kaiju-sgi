-- KAIJU SGI — privilégios e políticas RLS (etapa 0.2)
--
-- Matriz (L = ler, E = inserir/alterar; exclusão física só em "membros", pelo admin):
--   empresas ............................ admin L/E(alterar) · demais L
--   membros ............................. admin L/E/excluir · demais L (só a própria linha)
--   estabelecimentos, trabalhadores,
--   pgrs, nao_conformidades, acoes,
--   treinamentos, treinamentos_realizados  admin/tecnico_sst L/E · medico/cliente_leitura L
--   asos ................................ medico L/E · demais L
-- Criação de empresa: só pelo dono, fora da API (painel/SQL como postgres).

-- ---------------------------------------------------------------------------
-- Funções auxiliares (schema private, fora da API)
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER: lê "membros" sem passar pela RLS dela mesma (evita recursão).
create function private.empresas_com_papel(papeis public.papel[])
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.empresa_id
  from public.membros m
  join public.empresas e on e.id = m.empresa_id
  where m.usuario_id = auth.uid()
    and m.ativo
    and e.ativo
    and m.papel = any (papeis)
$$;

create function private.empresas_do_usuario()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select private.empresas_com_papel(enum_range(null::public.papel))
$$;

-- Impede que a empresa fique sem admin ativo (inclusive por auto-rebaixamento).
create function private.garantir_admin()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.papel = 'admin' and old.ativo
     and (tg_op = 'DELETE' or new.papel <> 'admin' or not new.ativo)
     and not exists (
       select 1 from public.membros m
       where m.empresa_id = old.empresa_id
         and m.usuario_id <> old.usuario_id
         and m.papel = 'admin'
         and m.ativo
     )
  then
    raise exception 'a empresa % ficaria sem admin ativo', old.empresa_id using errcode = 'KJ001';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger garantir_admin
  before update or delete on public.membros
  for each row execute function private.garantir_admin();

-- Troca de usuário ou de empresa num vínculo = excluir + inserir; simplifica a RLS.
create function private.travar_chave_membro()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.usuario_id is distinct from old.usuario_id then
    raise exception 'usuario_id de um vínculo não pode ser alterado' using errcode = 'KJ002';
  end if;
  return new;
end;
$$;

create trigger travar_chave_membro
  before update on public.membros
  for each row execute function private.travar_chave_membro();

revoke all on all functions in schema private from public, anon, authenticated;
grant usage on schema private to authenticated;
grant execute on function private.empresas_com_papel(public.papel[]) to authenticated;
grant execute on function private.empresas_do_usuario() to authenticated;

-- ---------------------------------------------------------------------------
-- Privilégios de tabela
-- ---------------------------------------------------------------------------
-- O Supabase concede ALL (inclusive DELETE e TRUNCATE, que ignora RLS) a anon e
-- authenticated por default privileges. Zeramos e concedemos só o necessário.
revoke all on all tables in schema public from anon, authenticated;

grant select, update on public.empresas to authenticated;
grant select, insert, update, delete on public.membros to authenticated;
grant select, insert, update on
  public.estabelecimentos, public.trabalhadores, public.pgrs, public.nao_conformidades,
  public.acoes, public.treinamentos, public.treinamentos_realizados, public.asos
  to authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.empresas                enable row level security;
alter table public.membros                 enable row level security;
alter table public.estabelecimentos        enable row level security;
alter table public.trabalhadores           enable row level security;
alter table public.pgrs                    enable row level security;
alter table public.nao_conformidades       enable row level security;
alter table public.acoes                   enable row level security;
alter table public.treinamentos            enable row level security;
alter table public.treinamentos_realizados enable row level security;
alter table public.asos                    enable row level security;

-- empresas
create policy empresas_select on public.empresas for select to authenticated
  using (id in (select private.empresas_do_usuario()));
create policy empresas_update on public.empresas for update to authenticated
  using      (id in (select private.empresas_com_papel('{admin}')))
  with check (id in (select private.empresas_com_papel('{admin}')));

-- membros
create policy membros_select on public.membros for select to authenticated
  using (
    -- Própria linha só enquanto o vínculo e a empresa estiverem ativos.
    (usuario_id = (select auth.uid()) and empresa_id in (select private.empresas_do_usuario()))
    or empresa_id in (select private.empresas_com_papel('{admin}'))
  );
create policy membros_insert on public.membros for insert to authenticated
  with check (empresa_id in (select private.empresas_com_papel('{admin}')));
create policy membros_update on public.membros for update to authenticated
  using      (empresa_id in (select private.empresas_com_papel('{admin}')))
  with check (empresa_id in (select private.empresas_com_papel('{admin}')));
create policy membros_delete on public.membros for delete to authenticated
  using (empresa_id in (select private.empresas_com_papel('{admin}')));

-- Tabelas de SST: todos os membros leem; admin e técnico escrevem.
do $$
declare
  t text;
begin
  foreach t in array array[
    'estabelecimentos', 'trabalhadores', 'pgrs', 'nao_conformidades',
    'acoes', 'treinamentos', 'treinamentos_realizados'
  ] loop
    execute format($f$
      create policy %1$s_select on public.%1$I for select to authenticated
        using (empresa_id in (select private.empresas_do_usuario()));
      create policy %1$s_insert on public.%1$I for insert to authenticated
        with check (empresa_id in (select private.empresas_com_papel('{admin,tecnico_sst}')));
      create policy %1$s_update on public.%1$I for update to authenticated
        using      (empresa_id in (select private.empresas_com_papel('{admin,tecnico_sst}')))
        with check (empresa_id in (select private.empresas_com_papel('{admin,tecnico_sst}')));
    $f$, t);
  end loop;
end;
$$;

-- asos: só o médico escreve
create policy asos_select on public.asos for select to authenticated
  using (empresa_id in (select private.empresas_do_usuario()));
create policy asos_insert on public.asos for insert to authenticated
  with check (empresa_id in (select private.empresas_com_papel('{medico}')));
create policy asos_update on public.asos for update to authenticated
  using      (empresa_id in (select private.empresas_com_papel('{medico}')))
  with check (empresa_id in (select private.empresas_com_papel('{medico}')));
