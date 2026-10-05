// Supabase falso para teste de tela: mesmo formato de resposta do supabase-js v2.
(function () {
  const USUARIO = { id: 'u-1', email: 'dono@teste.kaiju' };
  const EMP_A = '11111111-aaaa-4aaa-8aaa-111111111111';
  const EMP_B = '22222222-bbbb-4bbb-8bbb-222222222222';
  const XSS = '<img src=x onerror="window.__xss=1">';
  const hoje = new Date();
  const iso = d => d.toISOString().slice(0, 10);
  const dias = n => { const d = new Date(hoje); d.setDate(d.getDate() + n); return iso(d); };

  const tabelas = {
    membros: [
      { usuario_id: 'u-1', empresa_id: EMP_A, papel: 'admin', empresas: { razao_social: 'Alfa Construções', cnpj: '12345678000195' } },
      { usuario_id: 'u-1', empresa_id: EMP_B, papel: 'cliente_leitura', empresas: { razao_social: 'Beta Indústria', cnpj: '98765432000110' } }
    ],
    nao_conformidades: [
      { id: 'aaaaaa01-0000-4000-8000-000000000001', empresa_id: EMP_A, titulo: XSS, descricao: 'desc', setor: 'Obras',
        origem: 'auditoria_nr', severidade: 'alta', status: 'aberta', responsavel: 'Fulano', prazo: dias(10),
        data_identificacao: iso(hoje), norma_ref: 'NR-35', item_ref: '35.1.1', created_at: hoje.toISOString() },
      { id: 'aaaaaa02-0000-4000-8000-000000000002', empresa_id: EMP_A, titulo: 'Extintor vencido', descricao: 'd', setor: 'Geral',
        origem: 'inspecao', severidade: 'media', status: 'em_tratamento', responsavel: null, prazo: null,
        data_identificacao: iso(hoje), norma_ref: null, item_ref: null, created_at: hoje.toISOString() },
      { id: 'bbbbbb01-0000-4000-8000-000000000003', empresa_id: EMP_B, titulo: 'NC da Beta', descricao: 'd', setor: 'x',
        origem: 'outro', severidade: 'baixa', status: 'aberta', responsavel: null, prazo: null,
        data_identificacao: iso(hoje), norma_ref: null, item_ref: null, created_at: hoje.toISOString() }
    ],
    acoes: [
      { id: 'cccccc01-0000-4000-8000-000000000001', empresa_id: EMP_A, titulo: 'Instalar guarda-corpo', descricao: 'd', tipo: 'corretiva',
        prioridade: 'alta', setor: 'Obras', progresso: 40, status: 'em_andamento', responsavel: 'Ciclano', prazo: dias(-3),
        nc_id: 'aaaaaa01-0000-4000-8000-000000000001', created_at: hoje.toISOString() }
    ],
    asos: [
      { id: 'a1', empresa_id: EMP_A, trabalhador_id: 't1', tipo: 'periodico', data_exame: iso(hoje), resultado: 'apto', proximo_exame: dias(20) },
      { id: 'a2', empresa_id: EMP_A, trabalhador_id: 't2', tipo: 'admissional', data_exame: iso(hoje), resultado: 'apto', proximo_exame: dias(200) }
    ],
    pgrs: [
      { id: 'p1', empresa_id: EMP_A, versao: '1', status: 'vigente', data_elaboracao: iso(hoje), data_revisao_prevista: null },
      { id: 'p2', empresa_id: EMP_A, versao: '0', status: 'substituido', data_elaboracao: iso(hoje), data_revisao_prevista: null }
    ],
    treinamentos_realizados: [
      { id: 'r1', empresa_id: EMP_A, data_realizacao: dias(-400), valido_ate: dias(-35), instrutor: 'Instrutor X',
        treinamentos: { nome: 'Trabalho em altura', nr_ref: 'NR-35', carga_horaria_h: 8 }, trabalhadores: { nome: 'Fulano' } },
      { id: 'r2', empresa_id: EMP_A, data_realizacao: iso(hoje), valido_ate: dias(700), instrutor: null,
        treinamentos: { nome: 'NR-10 Básico', nr_ref: 'NR-10', carga_horaria_h: 40 }, trabalhadores: { nome: 'Ciclano' } }
    ],
    trabalhadores: [
      { id: 't1', empresa_id: EMP_A, data_desligamento: null }, { id: 't2', empresa_id: EMP_A, data_desligamento: null },
      { id: 't3', empresa_id: EMP_A, data_desligamento: '2025-01-01' }
    ]
  };
  window.__chamadas = [];

  function consulta(tabela) {
    const filtros = [];
    let opcoes = {};
    let operacao = 'select';
    let payload = null;
    let unico = false;
    const q = {
      select(_cols, opts) { if (operacao === 'select') opcoes = opts || {}; return q; },
      eq(c, v) { filtros.push(r => r[c] === v); return q; },
      is(c, v) { filtros.push(r => (r[c] ?? null) === v); return q; },
      order() { return q; },
      insert(l) { operacao = 'insert'; payload = l; return q; },
      update(l) { operacao = 'update'; payload = l; return q; },
      single() { unico = true; return q; },
      then(ok, erro) { return Promise.resolve(executar()).then(ok, erro); }
    };
    function executar() {
      window.__chamadas.push({ tabela, operacao, payload });
      const linhas = (tabelas[tabela] || []).filter(r => filtros.every(f => f(r)));
      if (operacao === 'insert') {
        const nova = { id: 'novo-' + Math.random().toString(16).slice(2, 10), created_at: new Date().toISOString(), status: 'aberta', ...payload };
        tabelas[tabela].push(nova);
        return { data: unico ? nova : [nova], error: null };
      }
      if (operacao === 'update') {
        linhas.forEach(r => Object.assign(r, payload));
        return { data: linhas.map(r => ({ id: r.id })), error: null };
      }
      if (opcoes.head) return { data: null, count: linhas.length, error: null };
      return { data: linhas, error: null };
    }
    return q;
  }

  let logado = false;
  window.supabase = {
    createClient() {
      return {
        auth: {
          async getSession() { return { data: { session: logado ? { user: USUARIO } : null } }; },
          async signInWithPassword({ email, password }) {
            if (email === USUARIO.email && password === 'certa') { logado = true; return { data: { user: USUARIO }, error: null }; }
            return { data: {}, error: { message: 'Invalid login credentials' } };
          },
          async signOut() { logado = false; return { error: null }; },
          onAuthStateChange() { return { data: { subscription: { unsubscribe() {} } } }; }
        },
        from: consulta
      };
    }
  };
})();
