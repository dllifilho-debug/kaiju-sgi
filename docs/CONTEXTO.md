# KAIJU SGI — Contexto do projeto

> Briefing registrado em 25/09/2026. Estado "atual" abaixo foi medido lendo o código nessa data;
> confira no disco antes de afirmar qualquer coisa como verdade presente.

## Produto

SaaS de gestão integrada **SST + Qualidade + Meio Ambiente** (ISO 9001, ISO 14001, ISO 45001),
multi-tenant, para **qualquer empresa**. Produto próprio do Diovanni (dono), com intenção de venda
futura. Não é vinculado a nenhum cliente — a menção a "SECONCI" no `kaiju-sgi-api` é resquício.

## Estado atual (medido em 25/09/2026)

### `dllifilho-debug/kaiju-sgi` (este repositório)
- Um único `index.html` (~108 KB), publicado no Vercel (`kaiju-sgi.vercel.app`, plano Hobby).
- ~~Login falso (`admin@empresa.com` / `admin123` no JS); números fixos no HTML; `API_URL` do
  Render.~~ Resolvidos na etapa 0.3 (05/10/2026) — ver "Estado após a etapa 0.3" abaixo.

### `dllifilho-debug/kaiju-sgi-api` (repositório separado)
- Express 5 no Render. Dados em arrays na memória — cada reinício volta ao `seed.js`.
- `pg`, `bcryptjs`, `jsonwebtoken` instalados e nunca usados.
- Sem autenticação: qualquer um cria/apaga. CORS aberto. **Desde a 0.3 o frontend não usa mais
  esta API.** Serviço **suspenso** no Render pelo dono em 05/10/2026 (não apagado; reversível
  com "Resume service"). Código preservado no GitHub.
- ~~`node_modules` versionado (893 arquivos).~~ Resolvido na etapa 0.1 (05/10/2026).
- **Erro conceitual**: a rota `/api/ltcats` guarda afastamentos/CAT. LTCAT é o Laudo Técnico das
  Condições Ambientais do Trabalho (Lei 8.213/1991, art. 58, §1º) — documento previdenciário,
  não registro de afastamento. CAT é a Comunicação de Acidente de Trabalho (Lei 8.213/1991, art. 22).
- **Dado sensível exposto**: o seed coloca CID dentro do ASO. Isso não pode existir em sistema
  acessado pela empresa-cliente.

## Decisões tomadas (não reabrir sem o dono)

1. **Supabase** (Postgres + Auth + RLS + Storage) substitui a API Express, que será aposentada.
   Sem backend próprio por enquanto; FastAPI só se uma regra de negócio exigir.
2. **Frontend** continua no Vercel, com `supabase-js`. Framework só quando a tela crescer.
3. **Repositórios públicos** (decisão do dono). Consequência: a chave `service_role` do Supabase
   **nunca** vai para o git. A chave `anon` pode ir — quem protege os dados é a RLS.
4. **Multi-tenant no banco**: toda tabela de negócio tem `empresa_id`; isolamento por RLS, nunca
   por filtro no frontend. Papéis: `admin` (dono), `tecnico_sst`, `medico`, `cliente_leitura`.
5. **Dado de saúde**: CID/diagnóstico nunca acessível à empresa-cliente — NR-7 define o conteúdo
   do ASO sem diagnóstico; sigilo médico; LGPD (Lei 13.709/2018) art. 5º, II e art. 11 (dado
   sensível). O dono do SaaS é **operador**; cada empresa-cliente é **controladora**.

### Decisões da etapa 0.2 (26/09/2026)

6. `admin` é **por empresa** (papel no vínculo), sem superadmin global que ignore a RLS. O dono do
   SaaS entra como membro de cada empresa que atende. **(aprovado pelo dono)**

Itens 7–10: confirmados pelo dono em 26/09/2026.

7. Tabela `trabalhadores` (com CPF) incluída — ASO e treinamento dependem dela.
8. Sem exclusão física fora de `membros`; histórico encerrado por `status`/`ativo`.
9. Cadastro público de usuário desligado; empresa e primeiro admin criados pelo dono no painel/SQL.
   Convite pela aplicação fica para uma Edge Function (secret no Supabase, nunca no git).
10. Controle de documentos (ISO 9001) e aspectos/impactos ambientais (ISO 14001): fora da 0.2.

Esquema, políticas e testes: `supabase/` (ver `supabase/README.md`).

### Projeto Supabase (criado em 05/10/2026)

- Projeto `kaiju-sgi`, região `sa-east-1` (São Paulo), plano Free — URL `https://rrleosgoxebbxmkgxpwz.supabase.co`.
- Criado com *Automatically expose new tables* desligado e *automatic RLS* ligado; cadastro público
  de usuários desligado; *Confirm email* ligado.
- Migrations 0001–0003 aplicadas pelo SQL Editor em 05/10/2026.
- Migration 0004 (campos de NC/ação da tela, aprovada pelo dono em 05/10/2026) aplicada pelo SQL
  Editor em 05/10/2026; testes no banco real: 535 ok, 0 falhas.
- Auth: Site URL `https://kaiju-sgi.vercel.app` e Redirect URL `https://kaiju-sgi.vercel.app/**`
  configurados pelo dono em 05/10/2026.
- O projeto `seconci-sst` (mesma org) é outro banco, de uso ainda não identificado: **não mexer**.
- Primeiro usuário: o dono, `admin` da "Empresa Demonstração (teste)" (CNPJ fictício
  11111111000111), criados em 05/10/2026.

### Estado após a etapa 0.3 (05/10/2026)

- `kaiju-sgi.vercel.app` com login real (Supabase Auth, e-mail/senha), testado pelo dono no site
  oficial: login, painel, gravação de NC (NC-EC4690).
- Frontend lê/grava no Supabase com a chave `publishable` (pública); isolamento pela RLS.
- supabase-js 2.117.2 e Chart.js 4.5.1 com versão fixa e SRI; escape de HTML em todo dado exibido.
- Vocabulário de status (decisão do dono, 05/10/2026): NC = Aberta → Em tratamento → Encerrada;
  Ação = Pendente → Em andamento → Concluída (NC só encerra após eficácia das ações — ISO 9001/45001, 10.2).
- Módulos sem banco (riscos, auditorias, meio ambiente, documentos, KPIs, compliance) aparecem como
  "em desenvolvimento", sem números.
- Teste de tela em `tests/e2e/` (Playwright + Supabase simulado): 40 verificações (63 desde as telas de senha; 88 desde a coluna "Obra" na lista de NCs); ver o README da pasta.
- Telas de senha (13/10/2026, branch `claude/awesome-fermat-f4z7qj`, ainda sem teste no Supabase real):
  "Esqueci minha senha" no login (`resetPasswordForEmail`, volta para a própria página e abre
  "Definir nova senha") e "Alterar senha" em Configurações (confere a senha atual antes do
  `updateUser`). Mínimo de 8 caracteres no cliente; o mínimo do servidor está no painel do
  Supabase [A MEDIR].

### Estado após a etapa 1 (13/10/2026)

- Migration 0005 (`enviar_nc_auditoria`) aplicada pelo SQL Editor em 09/10/2026; testes no banco
  real: 568 ok, 0 falhas (`kaiju-sgi` PR #11 corrigiu e-mails repetidos nas fixtures).
- `auditoria-nrs-08.streamlit.app` com `KAIJU_SUPABASE_URL` e `KAIJU_SUPABASE_CHAVE` (publishable)
  nos Secrets do Streamlit Cloud, cadastrados pelo dono em 09/10/2026.
- Testado pelo dono em produção em 13/10/2026 (modo demonstração, 1 NC, "Sem obra"): 1º envio
  "1 NC criada"; reenvio "0 criadas, 1 já estava no Kaiju"; NC-C6BFC8 apareceu no Kaiju com origem
  Auditoria NR, NR-18 18.9.2, Crítica, prazo 14/10/2026, e a ação corretiva vinculada.
- Tela "Obras e Unidades" no ar desde `kaiju-sgi` PR #14 (13/10/2026). Testado pelo dono no mesmo
  dia: obra cadastrada no Kaiju apareceu no app; envio com obra criou NC-74DF28; reenvio após
  reboot do app: "0 NCs criadas; 1 já estava no Kaiju e não foi alterada".
- Status de ação e cancelamento em cascata (com confirmação) no ar desde `kaiju-sgi` PR #13.
- Armadilha do Streamlit Cloud medida em 13/10/2026: após merge que muda `auditoria/`, o app
  recarregou `app.py` com o módulo `auditoria.kaiju` antigo (`AttributeError: resumo_envio`); o
  envio já tinha gravado e só a mensagem falhou. Remédio: *Reboot app* após cada merge desse tipo.
- Lista de NCs com a coluna "Obra" (nome da obra/unidade vinculada, inclusive inativa; a busca acha
  pelo nome) e bloqueio de encerrar NC com ação pendente/em andamento — branch
  `claude/festive-hawking-mr9fsa-ncs-obra`. O bloqueio é só na tela; o banco não impede.
- Telas "Esqueci minha senha" e "Alterar senha" no ar desde `kaiju-sgi` PR #12 (13/10/2026);
  envio de e-mail pelo SMTP padrão do Supabase **[A CONFERIR]** para usuários fora da equipe.

### Estado da etapa 2 (14/10/2026) — LEIA ISTO PRIMEIRO NO PRÓXIMO CHAT

**Decisões do dono (13/10/2026):** (1) PCMSO é tabela própria (`pcmsos`), separada do PGR;
(2) admin, tecnico_sst e medico gravam a matriz; o médico também cria PGR, só em `rascunho`;
(3) a matriz chega como `rascunho` e só o **médico** a torna `vigente` (com médico responsável,
NR-7 7.5.19.1 "f"); matriz com resultado do motor `PRELIMINAR` **não** vira vigente;
(4) ordem: 2a (banco) → 2b-1 (tela de PCMSO) → 2c (envio no app PCMSO) → 2b-2 (Trabalhadores e ASO).

- **2a — migration 0006 (`matriz_pcmso`)**: `kaiju-sgi` PR #17, mergeado em 14/10/2026. Aplicada no
  projeto `kaiju-sgi` (`rrleosgoxebbxmkgxpwz`) pelo conector Supabase do Claude em 14/10/2026
  (arquivo idêntico ao do `main`, mesmo sha256). Conferência estrutural no banco real: RLS em todas
  as tabelas, `empresa_id` NOT NULL, `anon` sem acesso, sem TRUNCATE, DELETE só em `membros`,
  carimbo em todas, 10 políticas novas, RPC `enviar_matriz_pcmso` SECURITY INVOKER sem EXECUTE
  para `anon`, 4 triggers de trava. **Suíte pgTAP completa no banco real: [A MEDIR]** — rodar
  `python3 supabase/tests-local/gerar_sql_editor.py` e colar no SQL Editor **do projeto kaiju-sgi**
  (não do seconci-sst); esperado `RESULTADO: 639 ok, 0 falhas`. Local (Postgres 16 + pgTAP):
  639 ok, 0 falhas.
- **Tabelas novas**: `pcmsos`, `ghes` (cargos `text[]`), `pcmso_exames` (momentos em `tipo_aso[]`,
  periodicidade ≥ 0), `ghe_riscos_aso` (veredito consta/conferir/nao_consta, NR-7 7.5.19.1 "c");
  `pgrs.origem_externa_id` (hash do PDF); `trabalhadores.ghe_id`. Erro `KJ004` = matriz/PCMSO travados.
- **Também no ar (13/10/2026)**: coluna "Obra" na lista de NCs e bloqueio (só na tela) de encerrar NC
  com ação pendente/em andamento — `kaiju-sgi` PR #16; nota de *Reboot app* no CLAUDE.md do
  `app-auditoria-nrs` — PR #86.
- **Próximo passo**: 2b-1 — tela de PCMSO no `index.html` (lista de PCMSOs por PGR, matriz por GHE,
  botão "Tornar vigente" só para `medico`, que exige nome/CRM do médico responsável e data; marcar o
  vigente anterior como `substituido` antes). Teste de tela em `tests/e2e` (hoje 88 verificações).
- **Pendente da 2b-2**: trabalhador aponta para o GHE de uma versão do PCMSO; quando um novo PCMSO
  entrar em vigor, a tela tem de sinalizar e pedir reconfirmação do GHE.

### Projeto Supabase `seconci-sst` — é o banco do app PCMSO (achado em 14/10/2026)

- `wmuflfqzdndiwpgwnexw`, mesma org. Tabelas `dicionario_dinamico`, `historico_laudos`,
  `ghe_mapeamentos` — exatamente as que `dllifilho-debug/automacao-pgr-agente-pcmso` usa
  (`config/db.py`, `testar_ghe_mapper.py`). Nome antigo: o app se chamava Seconci antes do rename.
  Confirmação definitiva [A CONFERIR]: `SUPABASE_URL` nos Secrets do Streamlit do app.
- **Segurança, medido em 14/10/2026**: `historico_laudos` e `dicionario_dinamico` **sem RLS**, com
  SELECT/INSERT/DELETE para `anon`; `ghe_mapeamentos` com RLS mas políticas `true` para `public`
  (leitura, insert e update); função `_set_atualizado_em` sem `search_path` fixo. As 3 tabelas
  estimadas com 0 linhas (`n_live_tup`, estimativa). Atividade de 13/10 ~18h20 (Brasília) foi só da
  infraestrutura Supabase (mgmt-api, reinício do PostgREST durante incidente da plataforma); nada
  alterado por nós.
- **Próximo passo, aprovado pelo dono em 14/10/2026**: preparar **proposta** de RLS para o
  seconci-sst no repositório do app PCMSO (CLAUDE.md próprio: branch `feat/<sessao>-<nome>`, push
  com autorização por turno, merge é do dono). Antes: confirmar qual chave o app usa
  (`SUPABASE_KEY`: `service_role` ignora RLS; `anon` precisaria de políticas). **Nada aplicado sem
  ok do dono.** O app grava por servidor (Streamlit), não por navegador.

### Pendências

- Etapa 2: a tabela `asos` guarda só NR-7 7.5.19.1 e) e g) (+ tipo e data); se o Kaiju for
  **emitir** ASO, faltam c) perigos/riscos do PGR, d) exames e datas, f) médico responsável
  pelo PCMSO.

## Plano

| Etapa | Entrega | Status |
|---|---|---|
| 0.1 | Tirar `node_modules` do git no `kaiju-sgi-api` (+ `.gitignore`). | ✅ 05/10/2026 — `kaiju-sgi-api` PR #1, merge `08fdf7a`; deploy no Render *Live* com Build Command `npm install`. |
| 0.2 | Esquema multi-tenant (empresas, usuários×empresa×papel, estabelecimentos/obras, PGRs, NCs, ações, treinamentos, ASOs sem CID) + políticas RLS + testes provando que empresa A não lê nem escreve na empresa B. **Entregar primeiro como proposta para revisão — nada é criado no Supabase antes do ok.** | ✅ 26/09/2026 — `kaiju-sgi` PR #1. Aplicado no Supabase em 05/10/2026; testes no banco real: 533 ok, 0 falhas. |
| 0.3 | Login real no frontend (senha fora do HTML); números da tela calculados dos dados ou removidos. | ✅ 05/10/2026 — `kaiju-sgi` PR #4; testado pelo dono no site oficial. |
| 1 | Integração: app de Auditoria de NRs → Não Conformidades + Planos de Ação. | ✅ 13/10/2026 — `kaiju-sgi` PR #10 (RPC `enviar_nc_auditoria`, migration 0005) e `app-auditoria-nrs` PR #84; ver "Estado após a etapa 1". Pendente: cadastro de obras no Kaiju. |
| 2 | Integração: app PCMSO → PGRs + vencimento de ASO por trabalhador. | Em andamento — 2a ✅ 14/10/2026 (`kaiju-sgi` PR #17, migration 0006 aplicada; suíte pgTAP no banco real [A MEDIR]); próximo: 2b-1. Ver "Estado da etapa 2". |

## Normas conferidas no texto oficial

Fonte: PDFs oficiais em `dllifilho-debug/automacao-pgr-agente-pcmso/normas` (Gov.br/MTE),
conferidos em 05/10/2026. O dono confirmou no Gov.br/MTE, na mesma data, que a NR-7 vigente
ainda é a da Portaria MTP nº 567/2022.

| Item | Arquivo (última alteração) | Conteúdo usado no Kaiju |
|---|---|---|
| NR-1 1.5.4.4.6 | `nr-01-atualizada-2025-i-3` (Portaria MTE nº 765/2025) | Avaliação de riscos revista a cada 2 anos ou nas situações listadas; 1.5.4.4.6.1: até 3 anos com certificação de SGSST (numeração retificada, DOU 30/07/2025) → `pgrs.data_revisao_prevista`. |
| NR-7 7.5.6 | `nr-07-atualizada-2022-1` (Portaria MTP nº 567/2022) | Exames admissional, periódico, retorno ao trabalho, mudança de riscos ocupacionais, demissional → enum `tipo_aso`. |
| NR-7 7.5.19.1 | `nr-07-atualizada-2022-1` (Portaria MTP nº 567/2022) | Conteúdo mínimo do ASO (a–g), sem diagnóstico → `asos` sem CID. |

## Repositórios relacionados (Python/Streamlit — ficam SEPARADOS)

- `dllifilho-debug/automacao-pgr-agente-pcmso`: motor de matriz de exames do PCMSO a partir do PGR
  (regras NR-7/NR-15), método rigoroso de testes, `CLAUDE.md` próprio.
- `dllifilho-debug/app-auditoria-nrs`: laudo de não conformidades a partir de fotos; cita item de
  NR verbatim dos PDFs do MTE ("o modelo escolhe, o código cita"). Publicado em
  `auditoria-nrs-08.streamlit.app`.

**Integração**: cada app ganha "Enviar para o Kaiju", gravando no Supabase **com o login do
usuário** (a RLS vale para eles também). Nenhum app carrega `service_role`. Não juntar códigos.

## Fontes oficiais

- NRs vigentes: Gov.br/MTE — Normas Regulamentadoras Vigentes.
- NHOs: Gov.br/Fundacentro — biblioteca de Normas de Higiene Ocupacional.
- Nunca usar versões de terceiros; sinalizar quando uma norma estiver em revisão.
