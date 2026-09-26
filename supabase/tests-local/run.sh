#!/usr/bin/env bash
# Roda migrations + testes pgTAP num Postgres local (sem Docker/Supabase CLI).
# Recria o banco a cada execução. Requer: psql, pg_prove, extensão pgtap instalada.
# Uso: PGHOST=... PGPORT=... PGUSER=postgres supabase/tests-local/run.sh
# Com Supabase CLI disponível, prefira: supabase db reset && supabase test db
set -euo pipefail

raiz="$(cd "$(dirname "$0")/../.." && pwd)"
banco="${KAIJU_TEST_DB:-kaiju_test}"
psql_q=(psql -X -q -v ON_ERROR_STOP=1)

"${psql_q[@]}" -d postgres -c "drop database if exists ${banco}" -c "create database ${banco}"
"${psql_q[@]}" -d "$banco" -c "alter database ${banco} set search_path = \"\$user\", public, extensions"

"${psql_q[@]}" -d "$banco" -f "$raiz/supabase/tests-local/shim_supabase.sql"
for m in "$raiz"/supabase/migrations/*.sql; do
  echo "migration: $(basename "$m")"
  "${psql_q[@]}" -d "$banco" -f "$m"
done

pg_prove -d "$banco" "$raiz"/supabase/tests/*.sql
