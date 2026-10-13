// Teste de tela do index.html com Chromium (Playwright), sem rede.
// T1: bibliotecas reais (do node_modules) — valida o SRI do HTML contra os pacotes do npm.
// T2: Supabase simulado (stub_supabase.js) — login, contagens, gravação, papéis, XSS, troca de senha,
//     "esqueci minha senha", logout.
// T3: volta do link de recuperação do e-mail (nova senha) e link expirado.
// Uso: cd tests/e2e && npm ci && npm test   (CHROMIUM_PATH=... para usar um Chromium já instalado)
import { chromium } from 'playwright';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const AQUI = dirname(fileURLToPath(import.meta.url));
const NM = join(AQUI, 'node_modules');
const HTML  = readFileSync(join(AQUI, '..', '..', 'index.html'), 'utf8');
// Versão errada no HTML (≠ package.json) faz o SRI falhar e o T1 acusa.
const CHART = readFileSync(join(NM, 'chart.js', 'dist', 'chart.umd.min.js'));
const SUPA  = readFileSync(join(NM, '@supabase', 'supabase-js', 'dist', 'umd', 'supabase.js'));
const STUB  = readFileSync(join(AQUI, 'stub_supabase.js'), 'utf8');
const versao = pkg => JSON.parse(readFileSync(join(NM, ...pkg.split('/'), 'package.json'), 'utf8')).version;

let falhas = 0;
const ok = (cond, msg) => { console.log(`${cond ? 'ok  ' : 'FALHA'} ${msg}`); if (!cond) falhas++; };

async function abrir(browser, html, fragmento = '') {
  const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
  const erros = [];
  page.on('pageerror', e => erros.push(String(e)));
  page.on('console', m => { if (m.type() === 'error' && !m.text().startsWith('Failed to load resource')) erros.push(m.text()); });
  // Falhas de rede só são aceitas nos hosts que o próprio teste bloqueia.
  page.on('requestfailed', r => {
    const u = r.url();
    if (!/^https:\/\/(cdnjs\.cloudflare\.com|fonts\.googleapis\.com|[a-z0-9]+\.supabase\.co)\//.test(u)) erros.push('rede: ' + u);
  });
  await page.route('https://kaiju.teste/', r => r.fulfill({ contentType: 'text/html', body: html }));
  await page.route('https://cdn.jsdelivr.net/npm/chart.js@*/**', r =>
    r.fulfill({ contentType: 'application/javascript', body: CHART, headers: { 'access-control-allow-origin': '*' } }));
  await page.route('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@*/**', r =>
    r.fulfill({ contentType: 'application/javascript', body: SUPA, headers: { 'access-control-allow-origin': '*' } }));
  await page.route('**/*supabase.co/**', r => r.abort());
  await page.route('https://cdnjs.cloudflare.com/**', r => r.abort());
  await page.route('https://fonts.googleapis.com/**', r => r.abort());
  await page.goto('https://kaiju.teste/' + fragmento);
  return { page, erros };
}

const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});

// ── T1: bibliotecas reais (SRI) + login sem rede ──
{
  for (const pkg of ['@supabase/supabase-js', 'chart.js']) {
    const v = versao(pkg);
    ok(HTML.includes(`cdn.jsdelivr.net/npm/${pkg}@${v}/`), `T1 index.html usa ${pkg}@${v}, a versão testada`);
  }
  const { page, erros } = await abrir(browser, HTML);
  await page.waitForFunction(() => document.getElementById('loadingOverlay').classList.contains('hidden'), null, { timeout: 15000 });
  ok(await page.evaluate(() => typeof window.supabase?.createClient === 'function'), 'T1 supabase-js carregou com SRI válido');
  ok(await page.evaluate(() => typeof window.Chart === 'function'), 'T1 Chart.js carregou com SRI válido');
  ok(!erros.some(e => /integrity/i.test(e)), 'T1 nenhum erro de integridade');
  ok(await page.inputValue('#loginEmail') === '' && await page.inputValue('#loginPassword') === '', 'T1 login sem credenciais pré-preenchidas');
  ok(!(await page.content()).includes('admin123'), 'T1 senha antiga ausente da página');
  await page.fill('#loginEmail', 'x@y.z'); await page.fill('#loginPassword', 'abc');
  await page.click('#btnLogin');
  await page.waitForFunction(() => getComputedStyle(document.getElementById('loginErro')).display !== 'none', null, { timeout: 15000 });
  ok(await page.isVisible('#loginErro'), 'T1 erro de login exibido sem rede: ' + (await page.textContent('#loginErro')));
  ok(await page.isVisible('#loginScreen'), 'T1 continua na tela de login');
  await page.close();
}

// ── T2: Supabase simulado ──
{
  const html = HTML.replace(
    /<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/@supabase[^>]*><\/script>/,
    `<script>${STUB}</script>`);
  ok(html !== HTML, 'T2 stub injetado');
  const { page, erros } = await abrir(browser, html);
  await page.waitForFunction(() => document.getElementById('loadingOverlay').classList.contains('hidden'));

  await page.fill('#loginEmail', 'dono@teste.kaiju'); await page.fill('#loginPassword', 'errada');
  await page.click('#btnLogin');
  await page.waitForSelector('#loginErro', { state: 'visible' });
  ok((await page.textContent('#loginErro')).includes('E-mail ou senha incorretos'), 'T2 senha errada → mensagem em PT-BR');

  await page.fill('#loginPassword', 'certa');
  await page.press('#loginPassword', 'Enter');
  await page.waitForSelector('#loginScreen.hidden');
  await page.waitForFunction(() => document.getElementById('count-ncs').textContent !== '0');
  const t = async id => (await page.textContent('#' + id)).trim();
  ok(await t('userName') === 'dono@teste.kaiju', 'T2 cabeçalho com e-mail do usuário');
  ok(await t('userRole') === 'Administrador', 'T2 papel exibido');
  ok(await t('dash-empresa') === 'Alfa Construções', 'T2 empresa ativa (ordem alfabética)');
  ok(await t('count-ncs') === '1', 'T2 NCs abertas da empresa A = 1 (NC da B não entra)');
  ok(await t('nc-stat-total') === '2', 'T2 total de NCs da A = 2');
  ok(await t('count-acoes') === '1', 'T2 ações em aberto = 1');
  ok(await t('count-pgrs') === '1', 'T2 PGRs vigentes = 1');
  ok(await t('stat-trabalhadores') === '2', 'T2 trabalhadores ativos = 2 (desligado fora)');
  ok(await t('safety-asos-vencendo') === '1', 'T2 ASOs a vencer em 30 dias = 1');
  ok(await t('training-vencidos') === '1' && await t('training-horas') === '48', 'T2 treinamentos: 1 vencido, 48 h');
  ok(await t('kanban-stat-atrasadas') === '1', 'T2 ação atrasada = 1');
  const pagina = await page.content();
  for (const falso of ['>127<', '94%', '87%', '91%', 'Lucia Mendes', 'SECONCI', '+2 novos', '>245<', '>356<']) {
    ok(!pagina.includes(falso), `T2 número/nome fictício ausente: ${falso}`);
  }

  await page.click('[data-page="nc"]');
  await page.waitForSelector('#nc-table-body tr');
  ok(await page.evaluate(() => window.__xss === undefined), 'T2 XSS no título da NC não executou');
  ok((await page.textContent('#nc-table-body')).includes('<img src=x'), 'T2 título malicioso aparece como texto');
  ok((await page.locator('#nc-table-body tr').count()) === 2, 'T2 tabela de NCs com 2 linhas');

  // Obras e unidades
  await page.click('[data-page="sites"]');
  const linhasObra = () => page.locator('#obras-table-body tr').count();
  ok(await linhasObra() === 1 && (await page.textContent('#obras-table-body')).includes('Residencial Alfa'),
     'T2 obras: só as ativas da empresa A (Beta e inativa fora)');
  ok((await page.textContent('#obras-table-body')).includes('12.345.67890/12'), 'T2 obras: CNO formatado');
  await page.check('#obras-mostrar-inativas');
  ok(await linhasObra() === 2, 'T2 obras: "mostrar inativas" inclui a desativada');
  await page.uncheck('#obras-mostrar-inativas');

  await page.click('#btnNovaObra');
  await page.fill('#obra-nome', 'Edifício Aurora — Torre B');
  await page.fill('#obra-cno', '12.345');
  await page.click('#btnSalvarObra');
  ok((await page.textContent('#obra-msg')).includes('12 dígitos'), 'T2 obras: CNO incompleto recusado');
  await page.fill('#obra-cno', '98.765.43210/98');
  await page.fill('#obra-endereco', 'Av. B, 200');
  await page.click('#btnSalvarObra');
  await page.waitForFunction(() => document.querySelectorAll('#obras-table-body tr').length === 2);
  const insObra = await page.evaluate(() => window.__chamadas.find(c => c.tabela === 'estabelecimentos' && c.operacao === 'insert'));
  ok(insObra && insObra.payload.empresa_id === '11111111-aaaa-4aaa-8aaa-111111111111' && insObra.payload.tipo === 'obra'
     && insObra.payload.cno === '987654321098' && insObra.payload.cnpj === null && insObra.payload.nome === 'Edifício Aurora — Torre B',
     'T2 obras: nova obra gravada com empresa_id, tipo e CNO só com dígitos');

  await page.click('#obras-table-body button[onclick*="abrirObra(\'e-1\')"]');
  ok(await page.inputValue('#obra-nome') === 'Residencial Alfa', 'T2 obras: editar abre com os dados');
  await page.fill('#obra-nome', 'Residencial Alfa II');
  await page.click('#btnSalvarObra');
  await page.waitForFunction(() => document.getElementById('obras-table-body').textContent.includes('Residencial Alfa II'));
  const updObra = await page.evaluate(() => window.__chamadas.filter(c => c.tabela === 'estabelecimentos' && c.operacao === 'update').at(-1));
  ok(updObra && updObra.payload.nome === 'Residencial Alfa II' && !('empresa_id' in updObra.payload), 'T2 obras: edição não mexe em empresa_id');

  page.once('dialog', d => d.accept());
  await page.click('#obras-table-body button[onclick*="alternarObraAtiva(\'e-1\')"]');
  await page.waitForFunction(() => document.querySelectorAll('#obras-table-body tr').length === 1);
  const desat = await page.evaluate(() => window.__chamadas.filter(c => c.tabela === 'estabelecimentos' && c.operacao === 'update').at(-1));
  ok(desat.payload.ativo === false && Object.keys(desat.payload).length === 1, 'T2 obras: desativar só muda "ativo" (sem exclusão)');

  await page.click('[data-page="dashboard"]');
  await page.click('.fab-btn');
  await page.click('.fab-menu-item:has-text("Nova Não Conformidade")');
  await page.fill('#nc-titulo', 'Escada sem corrimão');
  await page.fill('#nc-responsavel', 'Beltrano');
  page.once('dialog', d => d.accept());
  await page.click('button:has-text("Registrar NC")');
  await page.waitForFunction(() => document.getElementById('nc-stat-total').textContent === '3');
  const ins = await page.evaluate(() => window.__chamadas.find(c => c.operacao === 'insert' && c.tabela === 'nao_conformidades'));
  ok(ins && ins.tabela === 'nao_conformidades' && ins.payload.empresa_id === '11111111-aaaa-4aaa-8aaa-111111111111'
     && ins.payload.titulo === 'Escada sem corrimão' && ins.payload.origem === 'inspecao', 'T2 NC gravada com empresa_id e campos certos');

  await page.click('.fab-btn');
  await page.click('.fab-menu-item:has-text("Novo Plano de Ação")');
  ok((await page.locator('#acao-ncid option').count()) === 4, 'T2 lista de NCs abertas/em tratamento para vincular à ação');
  await page.click('#actionModal .modal-close');

  
  await page.selectOption('#empresaSelect', '22222222-bbbb-4bbb-8bbb-222222222222');
  await page.waitForFunction(() => document.getElementById('userRole').textContent === 'Cliente (leitura)');
  ok(await t('nc-stat-total') === '1', 'T2 troca de empresa: só NCs da B');
  await page.click('[data-page="sites"]');
  ok(!(await page.isVisible('#btnNovaObra')) && (await page.locator('#obras-table-body button').count()) === 0
     && (await page.textContent('#obras-table-body')).includes('Fábrica Beta'),
     'T2 obras: cliente_leitura vê só as da B, sem botões de cadastro');
  await page.click('[data-page="dashboard"]');
  let alerta = '';
  page.once('dialog', d => { alerta = d.message(); d.accept(); });
  await page.click('.fab-btn');
  await page.click('.fab-menu-item:has-text("Nova Não Conformidade")');
  ok(alerta.includes('somente leitura'), 'T2 cliente_leitura não abre formulário de NC');

  // Alterar senha (Configurações)
  await page.click('[data-page="settings"]');
  const msgSenha = async () => (await page.textContent('#trocarSenhaMsg')).trim();
  await page.fill('#senhaAtual', 'errada'); await page.fill('#senhaNova', 'NovaSenha#1'); await page.fill('#senhaConfirma', 'NovaSenha#1');
  await page.click('#btnTrocarSenha');
  await page.waitForFunction(() => document.getElementById('trocarSenhaMsg').textContent !== '');
  ok((await msgSenha()) === 'Senha atual incorreta.', 'T2 trocar senha: senha atual errada recusada');
  ok(!(await page.evaluate(() => window.__auth.some(a => a.op === 'update'))), 'T2 trocar senha: sem updateUser quando a atual não confere');
  await page.fill('#senhaAtual', 'certa'); await page.fill('#senhaConfirma', 'Outra#123');
  await page.click('#btnTrocarSenha');
  ok((await msgSenha()).includes('não confere'), 'T2 trocar senha: confirmação divergente recusada');
  await page.fill('#senhaNova', 'curta'); await page.fill('#senhaConfirma', 'curta');
  await page.click('#btnTrocarSenha');
  ok((await msgSenha()).includes('pelo menos 8'), 'T2 trocar senha: mínimo de 8 caracteres');
  await page.fill('#senhaNova', 'NovaSenha#1'); await page.fill('#senhaConfirma', 'NovaSenha#1');
  await page.click('#btnTrocarSenha');
  await page.waitForFunction(() => document.getElementById('trocarSenhaMsg').classList.contains('ok'));
  const upd = await page.evaluate(() => window.__auth.filter(a => a.op === 'update'));
  ok(upd.length === 1 && upd[0].attrs.password === 'NovaSenha#1', 'T2 trocar senha: updateUser com a nova senha');
  ok(await page.inputValue('#senhaAtual') === '' && await page.inputValue('#senhaNova') === '', 'T2 trocar senha: campos limpos após sucesso');

  await page.click('text=Sair');
  await page.waitForSelector('#loginScreen:not(.hidden)');
  ok(true, 'T2 logout volta ao login');
  await page.fill('#loginEmail', 'dono@teste.kaiju'); await page.fill('#loginPassword', 'certa');
  await page.click('#btnLogin');
  await page.waitForSelector('#loginErro', { state: 'visible' });
  ok(await page.isVisible('#loginScreen'), 'T2 senha antiga deixa de valer');
  await page.fill('#loginPassword', 'NovaSenha#1');
  await page.click('#btnLogin');
  await page.waitForSelector('#loginScreen.hidden');
  ok(true, 'T2 nova senha entra');
  await page.click('text=Sair');
  await page.waitForSelector('#loginScreen:not(.hidden)');

  // Esqueci minha senha
  await page.fill('#loginEmail', 'alguem@teste.kaiju');
  await page.click('#linkEsqueci');
  ok(await page.isVisible('#painelEsqueci') && !(await page.isVisible('#painelLogin')), 'T2 esqueci: painel de recuperação aberto');
  ok(await page.inputValue('#esqueciEmail') === 'alguem@teste.kaiju', 'T2 esqueci: e-mail do login aproveitado');
  await page.fill('#esqueciEmail', 'invalido');
  await page.click('#btnEsqueci');
  ok((await page.textContent('#loginErro')).includes('e-mail válido'), 'T2 esqueci: e-mail inválido recusado no cliente');
  await page.fill('#esqueciEmail', 'alguem@teste.kaiju');
  await page.click('#btnEsqueci');
  await page.waitForSelector('#loginOk', { state: 'visible' });
  ok((await page.textContent('#loginOk')).includes('Se o e-mail estiver cadastrado'), 'T2 esqueci: resposta neutra (não revela se a conta existe)');
  const reset = await page.evaluate(() => window.__auth.find(a => a.op === 'reset'));
  ok(reset && reset.email === 'alguem@teste.kaiju' && reset.redirectTo === 'https://kaiju.teste/', 'T2 esqueci: resetPasswordForEmail com redirectTo da própria página');
  await page.click('#painelEsqueci .login-link');
  ok(await page.isVisible('#painelLogin'), 'T2 esqueci: voltar ao login');

  ok(erros.length === 0, 'T2 sem erros de JS no console' + (erros.length ? ': ' + erros.join(' | ') : ''));
  await page.close();
}

// ── T3: volta do link do e-mail (recuperação) ──
{
  const html = HTML.replace(
    /<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/@supabase[^>]*><\/script>/,
    `<script>${STUB}</script>`);
  const { page, erros } = await abrir(browser, html, '#access_token=x&type=recovery');
  await page.waitForFunction(() => document.getElementById('loadingOverlay').classList.contains('hidden'));
  ok(await page.isVisible('#painelNovaSenha') && await page.isVisible('#loginScreen'), 'T3 link de recuperação abre "Definir nova senha", sem entrar no sistema');
  ok(!page.url().includes('access_token'), 'T3 tokens removidos da barra de endereço');
  ok((await page.textContent('#novaSenhaConta')).includes('dono@teste.kaiju'), 'T3 mostra a conta');
  await page.fill('#recNova', 'abc'); await page.fill('#recConfirma', 'abc');
  await page.click('#btnNovaSenha');
  ok((await page.textContent('#loginErro')).includes('pelo menos 8'), 'T3 senha curta recusada');
  await page.fill('#recNova', 'certa123'); await page.fill('#recConfirma', 'certa123');
  await page.click('#btnNovaSenha');
  await page.waitForSelector('#loginScreen.hidden');
  ok((await page.textContent('#userName')).trim() === 'dono@teste.kaiju', 'T3 nova senha salva e entra no sistema');
  const upd = await page.evaluate(() => window.__auth.filter(a => a.op === 'update'));
  ok(upd.length === 1 && upd[0].attrs.password === 'certa123', 'T3 updateUser com a nova senha');
  ok(erros.length === 0, 'T3 sem erros de JS no console' + (erros.length ? ': ' + erros.join(' | ') : ''));
  await page.close();

  const r2 = await abrir(browser, html, '#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired');
  await r2.page.waitForFunction(() => document.getElementById('loadingOverlay').classList.contains('hidden'));
  ok(await r2.page.isVisible('#painelEsqueci') && (await r2.page.textContent('#loginErro')).includes('expirou'), 'T3 link expirado → aviso e painel para pedir outro');
  ok(r2.erros.length === 0, 'T3 link expirado sem erros de JS');
  await r2.page.close();
}

await browser.close();
console.log(falhas ? `\n${falhas} FALHA(S)` : '\nTODOS OK');
process.exit(falhas ? 1 : 0);
