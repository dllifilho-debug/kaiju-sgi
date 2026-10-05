# Teste de tela (e2e)

Abre o `index.html` no Chromium (Playwright) **sem rede**:

- **T1 — bibliotecas reais:** serve supabase-js e Chart.js a partir do `node_modules` e confere que
  o `index.html` cita as mesmas versões do `package.json` e que o SRI (hash) bate.
- **T2 — Supabase simulado** (`stub_supabase.js`): login com senha errada/certa, contagens do
  painel, NC gravada com o `empresa_id` certo, troca de empresa, bloqueio do papel
  `cliente_leitura`, XSS não executa, logout, nenhum erro de JS.

```bash
cd tests/e2e
npm ci
npm test            # esperado: TODOS OK
```

Chromium já instalado em outro caminho: `CHROMIUM_PATH=/caminho/do/chrome npm test`.

**Ao atualizar uma biblioteca no `index.html`:** mude a versão aqui no `package.json`, rode
`npm install`, recalcule o SRI do arquivo do pacote
(`openssl dgst -sha384 -binary <arquivo> | openssl base64 -A`) e rode o teste.

Não testa o Supabase real (o login real foi conferido manualmente pelo dono no site em 05/10/2026);
o isolamento entre empresas é testado no banco, em `supabase/tests/`.
