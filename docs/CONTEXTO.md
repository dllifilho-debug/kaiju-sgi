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
  esta API**; ela segue no ar no Render (aposentar — decisão pendente do dono).
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

### Pendências

- Supabase → Authentication → URL Configuration: Site URL `https://kaiju-sgi.vercel.app` e
  Redirect URL `https://kaiju-sgi.vercel.app/**` — confirmar se o dono salvou.
- Aposentar a API Express no Render (sugestão: suspender o serviço, sem apagar).
- Itens de norma citados em comentários ainda não conferidos no texto vigente (Gov.br/MTE):
  NR-1 1.5.4.4.6 e NR-7 7.5.19.1.
- Testes de tela (Playwright + Supabase simulado) ficaram fora do repositório; versionar se
  o frontend crescer.

## Plano

| Etapa | Entrega | Status |
|---|---|---|
| 0.1 | Tirar `node_modules` do git no `kaiju-sgi-api` (+ `.gitignore`). | ✅ 05/10/2026 — `kaiju-sgi-api` PR #1, merge `08fdf7a`; deploy no Render *Live* com Build Command `npm install`. |
| 0.2 | Esquema multi-tenant (empresas, usuários×empresa×papel, estabelecimentos/obras, PGRs, NCs, ações, treinamentos, ASOs sem CID) + políticas RLS + testes provando que empresa A não lê nem escreve na empresa B. **Entregar primeiro como proposta para revisão — nada é criado no Supabase antes do ok.** | ✅ 26/09/2026 — `kaiju-sgi` PR #1. Aplicado no Supabase em 05/10/2026; testes no banco real: 533 ok, 0 falhas. |
| 0.3 | Login real no frontend (senha fora do HTML); números da tela calculados dos dados ou removidos. | ✅ 05/10/2026 — `kaiju-sgi` PR #4; testado pelo dono no site oficial. |
| 1 | Integração: app de Auditoria de NRs → Não Conformidades + Planos de Ação. | **Próxima.** Começar lendo `dllifilho-debug/app-auditoria-nrs` e trazendo proposta antes de codar. |
| 2 | Integração: app PCMSO → PGRs + vencimento de ASO por trabalhador. | — |

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
