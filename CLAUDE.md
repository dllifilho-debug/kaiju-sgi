# CLAUDE.md — KAIJU SGI

**Leia `docs/CONTEXTO.md` primeiro.** Ele tem o produto, o estado medido, as decisões tomadas e o plano.

## Regras de método

- PT-BR.
- Citar NR/NHO pelo número; fonte oficial Gov.br/MTE (NRs vigentes) e Gov.br/Fundacentro (NHOs).
  Sinalizar norma em revisão.
- Push só com autorização explícita do Diovanni **no turno**. Commit local é livre.
- Divergência entre o medido e o esperado = **parar e reportar**, nunca ajustar para bater.
- Número não medido na sessão sai marcado **[A MEDIR]**.
- Chave `service_role` do Supabase **nunca** no git (repositórios são públicos). `anon` pode.
- Isolamento entre empresas é responsabilidade da RLS, nunca de filtro no frontend.
- CID/diagnóstico nunca acessível à empresa-cliente (NR-7; LGPD art. 11).
- Nada é criado no Supabase (projeto, tabela, política) sem ok explícito do dono sobre a proposta.
