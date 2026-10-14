# Banco — Supabase

Esquema multi-tenant do KAIJU SGI (etapa 0.2). Isolamento entre empresas por RLS; ver
`docs/CONTEXTO.md` para as decisões.

```
migrations/
  20260926000001_esquema_base.sql   tabelas, tipos, FKs compostas, trigger carimbar
  20260926000002_rls.sql            privilégios, funções auxiliares, políticas
  20260926000003_storage.sql        bucket privado "documentos" + políticas
  20261005000004_campos_nc_acao.sql campos de tratamento de NC/ação usados pelo frontend
  20261009000005_enviar_nc_auditoria.sql  RPC do "Enviar para o Kaiju" (app-auditoria-nrs)
  20261013000006_matriz_pcmso.sql   matriz do PCMSO por GHE + RPC do app PCMSO (PROPOSTA, não aplicada)
tests/                              pgTAP (rodam também com `supabase test db`)
tests-local/                        shim + runner para Postgres puro, sem Docker
```

## Rodar os testes

Com Supabase CLI e Docker:

```bash
supabase db reset && supabase test db
```

Sem Docker (Postgres 16 + pgTAP + pg_prove):

```bash
PGHOST=... PGPORT=... PGUSER=postgres supabase/tests-local/run.sh
```

No SQL Editor do Supabase (sem CLI): gerar o script e colar numa aba nova.

```bash
python3 supabase/tests-local/gerar_sql_editor.py > testes_sql_editor.sql
```

O script termina **sempre** com o erro `RESULTADO: N ok, M falhas` — proposital: o erro desfaz a
transação e nada dos testes fica gravado. Esperado: `M = 0`.

O shim (`tests-local/shim_supabase.sql`) emula só o que as migrations usam: papéis
`anon`/`authenticated`/`service_role`, `auth.uid()`, default privileges do schema `public` e
`storage.objects`. Não aplicar em projeto Supabase.

## Matriz de acesso

| Tabela | admin | tecnico_sst | medico | cliente_leitura |
|---|---|---|---|---|
| empresas | ler, alterar | ler | ler | ler |
| membros | ler, inserir, alterar, excluir | própria linha | própria linha | própria linha |
| estabelecimentos, trabalhadores, pgrs, nao_conformidades, acoes, treinamentos, treinamentos_realizados | ler, inserir, alterar | ler, inserir, alterar | ler | ler |
| asos | ler | ler | ler, inserir, alterar | ler |
| pgrs (0006, adicional) | — | — | inserir, só em `rascunho` | — |
| pcmsos (0006) | ler, inserir | ler, inserir | ler, inserir, alterar | ler |
| ghes, pcmso_exames, ghe_riscos_aso (0006) | ler, inserir | ler, inserir | ler, inserir | ler |
| storage `documentos/{empresa_id}/…` | ler, gravar, excluir | ler, gravar | ler, gravar | ler |

- `anon` não tem privilégio em nenhuma tabela.
- Sem exclusão física fora de `membros`: encerra-se por `status`/`ativo`.
- Vínculo inativo ou empresa inativa = nenhum acesso.
- A empresa sempre mantém pelo menos um admin ativo (erro `KJ001`).
- `empresa_id` não muda depois de gravado (erro `KJ002`).
- `enviar_nc_auditoria(empresa, obra, itens)`: SECURITY INVOKER — mesmas permissões de inserir NC
  (admin/tecnico_sst); lote atômico; reenvio idempotente por `origem_externa_id`, sem sobrescrever
  NC já existente. Erro `KJ003` = payload inválido.
- `enviar_matriz_pcmso(empresa, obra, matriz)` (0006): SECURITY INVOKER; admin/tecnico_sst/medico;
  atômica; reenvio idempotente por `origem_externa_id` do PCMSO; PGR reusado pelo hash do PDF.
  PCMSO: `rascunho` → `vigente` (só o médico, com médico responsável — NR-7 7.5.19.1 "f" — e só
  com resultado do motor `OK`) → `substituido`; um vigente por PGR. Matriz (ghes, exames, riscos)
  só recebe INSERT, e só com o PCMSO em rascunho. Erro `KJ004` = matriz/PCMSO travados.
- Storage: o Supabase bloqueia `DELETE` direto em `storage.objects` (`storage.protect_delete`,
  erro `42501`); exclusão de arquivo só pela API de Storage, onde vale a política acima.

## Ao aplicar num projeto Supabase (após ok do dono)

1. Authentication → desligar cadastro público (*Allow new users to sign up*).
2. `supabase link` + `supabase db push`.
3. Criar empresa e primeiro admin pelo SQL Editor (roda como `postgres`; a API não cria empresa):

   ```sql
   with e as (
     insert into public.empresas (razao_social, cnpj) values ('<razão social>', '<14 dígitos>')
     returning id
   )
   insert into public.membros (usuario_id, empresa_id, papel)
   select '<uuid do usuário em auth.users>', id, 'admin' from e;
   ```

4. Rodar `supabase test db` contra o banco local do CLI para confirmar o mesmo resultado do
   shim.

A chave `service_role` nunca entra no git nem nos apps.
