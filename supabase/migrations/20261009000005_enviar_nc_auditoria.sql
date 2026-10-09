-- KAIJU SGI — "Enviar para o Kaiju" do app-auditoria-nrs (etapa 1)
--
-- Uma chamada grava o lote inteiro: cada item vira uma NC (origem 'auditoria_nr') e, se trouxer
-- ação, a ação corretiva vinculada — tudo na mesma transação. Qualquer item inválido desfaz o lote.
--
-- Idempotência: a chave é o unique (empresa_id, origem, origem_externa_id) da 0.2. Reenviar um
-- item que já existe não altera nada — nem a NC (que pode já estar em tratamento no Kaiju) nem
-- as ações; o item volta como 'ja_existia'.
--
-- SECURITY INVOKER: roda com o usuário logado no app. RLS, papéis (só admin/tecnico_sst
-- escrevem), FKs compostas e o carimbo de autoria valem exatamente como num INSERT direto.
-- Nenhum objeto existente é alterado por esta migration.

create function public.enviar_nc_auditoria(
  p_empresa_id          uuid,
  p_estabelecimento_id  uuid,
  p_itens               jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  item       jsonb;
  acao       jsonb;
  ref        text;
  v_nc       uuid;
  v_data     date;
  resultado  jsonb := '[]'::jsonb;
begin
  if p_empresa_id is null then
    raise exception 'empresa não informada' using errcode = 'KJ003';
  end if;
  if jsonb_typeof(p_itens) is distinct from 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'itens deve ser uma lista não vazia' using errcode = 'KJ003';
  end if;
  -- Lote real chega a 100 fotos com poucas NCs cada; o teto barra payload acidental.
  if jsonb_array_length(p_itens) > 1000 then
    raise exception 'lote com mais de 1000 itens' using errcode = 'KJ003';
  end if;

  for item in select value from jsonb_array_elements(p_itens) loop
    ref := nullif(btrim(item ->> 'origem_externa_id'), '');
    if ref is null then
      raise exception 'item sem origem_externa_id' using errcode = 'KJ003';
    end if;
    if nullif(btrim(item ->> 'descricao'), '') is null then
      raise exception 'item % sem descricao', ref using errcode = 'KJ003';
    end if;
    acao := item -> 'acao';
    if acao is not null and jsonb_typeof(acao) <> 'null'
       and nullif(btrim(acao ->> 'descricao'), '') is null then
      raise exception 'ação do item % sem descricao', ref using errcode = 'KJ003';
    end if;

    v_data := coalesce((item ->> 'data_identificacao')::date, current_date);
    v_nc := null;

    insert into public.nao_conformidades (
      empresa_id, estabelecimento_id, origem, origem_externa_id, titulo, descricao,
      norma_ref, item_ref, severidade, setor, data_identificacao, prazo
    ) values (
      p_empresa_id, p_estabelecimento_id, 'auditoria_nr', ref, item ->> 'titulo', item ->> 'descricao',
      item ->> 'norma_ref', item ->> 'item_ref', (item ->> 'severidade')::public.severidade,
      item ->> 'setor', v_data, (item ->> 'prazo')::date
    )
    on conflict (empresa_id, origem, origem_externa_id) do nothing
    returning id into v_nc;

    if v_nc is null then
      select nc.id into v_nc
      from public.nao_conformidades nc
      where nc.empresa_id = p_empresa_id
        and nc.origem = 'auditoria_nr'
        and nc.origem_externa_id = ref;
      resultado := resultado || jsonb_build_object(
        'origem_externa_id', ref, 'nc_id', v_nc, 'situacao', 'ja_existia');
      continue;
    end if;

    if acao is not null and jsonb_typeof(acao) <> 'null' then
      insert into public.acoes (
        empresa_id, nc_id, titulo, descricao, tipo, prioridade, setor, prazo
      ) values (
        p_empresa_id, v_nc, acao ->> 'titulo', acao ->> 'descricao',
        coalesce((acao ->> 'tipo')::public.tipo_acao, 'corretiva'),
        (acao ->> 'prioridade')::public.severidade, item ->> 'setor', (acao ->> 'prazo')::date
      );
    end if;

    resultado := resultado || jsonb_build_object(
      'origem_externa_id', ref, 'nc_id', v_nc, 'situacao', 'criada');
  end loop;

  return resultado;
end;
$$;

-- Default privileges do Supabase dão EXECUTE em public a anon; só quem tem login chama.
revoke all on function public.enviar_nc_auditoria(uuid, uuid, jsonb) from public, anon;
grant execute on function public.enviar_nc_auditoria(uuid, uuid, jsonb) to authenticated;
