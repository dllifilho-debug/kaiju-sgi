"""Gera um script único dos testes pgTAP para colar no SQL Editor do Supabase.

O SQL Editor mostra só o resultado da última instrução. O script gerado acumula as
linhas TAP numa tabela temporária e termina com RAISE EXCEPTION contendo o placar:
o erro é proposital — aborta a transação e garante que nada dos testes fica gravado.

Uso: python3 supabase/tests-local/gerar_sql_editor.py > saida.sql
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[2]
TESTES = sorted((RAIZ / "supabase" / "tests").glob("*.test.sql"))

CABECALHO = """\
-- Testes de isolamento do KAIJU SGI para o SQL Editor do Supabase.
-- GERADO por supabase/tests-local/gerar_sql_editor.py — não editar à mão.
-- Termina SEMPRE com um erro "RESULTADO: ..." de propósito: o erro desfaz a transação,
-- então nenhum dado de teste fica no banco.
begin;
create extension if not exists pgtap with schema extensions;
create temp table tap (n serial, linha text) on commit drop;
select no_plan();
"""

RODAPE = """\
do $$
declare
  ok_n int;
  falhas int;
  detalhe text;
begin
  select count(*) filter (where linha like 'ok %'),
         count(*) filter (where linha like 'not ok %'),
         string_agg(linha, E'\\n' order by n) filter (where linha like 'not ok %')
    into ok_n, falhas, detalhe
  from tap;
  raise exception 'RESULTADO: % ok, % falhas%', ok_n, falhas,
    coalesce(E'\\n' || detalhe, '');
end;
$$;
"""


def converter(sql: str) -> str:
    sql = re.sub(r"^\s*begin;\s*$", "", sql, flags=re.M)
    sql = re.sub(r"^\s*rollback;\s*$", "", sql, flags=re.M)
    sql = re.sub(r"^\s*create extension if not exists pgtap.*$", "", sql, flags=re.M)
    sql = re.sub(r"^\s*select \* from finish\(\);\s*$", "", sql, flags=re.M)
    # plan(...) pode ter parênteses aninhados; remove a instrução inteira até o ';'
    sql = re.sub(r"^select plan\(.*?\);\s*$", "", sql, flags=re.M | re.S)
    # Asserções no nível superior passam a ser gravadas em "tap".
    sql = re.sub(r"^select is\(", "insert into tap (linha) select is(", sql, flags=re.M)
    return sql


def main() -> int:
    if not TESTES:
        print("nenhum teste em supabase/tests", file=sys.stderr)
        return 1
    partes = [CABECALHO]
    for arq in TESTES:
        partes.append(f"\n-- ===== {arq.name} =====\n")
        partes.append(converter(arq.read_text(encoding="utf-8")))
    partes.append(RODAPE)
    sys.stdout.write("".join(partes))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
