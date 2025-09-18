-- 004_foundation_full.sql: Полный DDL для Foundation II/III

-- Роли и права
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'imperium') THEN
    CREATE ROLE imperium LOGIN PASSWORD 'ImperiumTestPass';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_reader') THEN
    CREATE ROLE api_reader;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_writer') THEN
    CREATE ROLE api_writer;
  END IF;
END
$$;

-- Таблицы
CREATE TABLE IF NOT EXISTS public.events (
  id BIGSERIAL PRIMARY KEY,
  type TEXT NOT NULL,
  source TEXT,
  payload JSONB,
  status TEXT DEFAULT 'pending',
  created_at TIMESTAMP DEFAULT now(),
  updated_at TIMESTAMP DEFAULT now(),
  metadata JSONB,
  correlation_id TEXT UNIQUE
);

CREATE TABLE IF NOT EXISTS public.audit_queue (
  event_id BIGINT REFERENCES public.events(id) ON DELETE CASCADE,
  status TEXT NOT NULL,
  processed_at TIMESTAMP,
  auditor TEXT,
  PRIMARY KEY (event_id)
);

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS public.embeddings (
  event_id BIGINT PRIMARY KEY REFERENCES public.events(id) ON DELETE CASCADE,
  vector vector(1536)
);

-- Индексы
CREATE INDEX IF NOT EXISTS idx_events_status ON public.events(status);
CREATE INDEX IF NOT EXISTS idx_events_created_at ON public.events(created_at);
CREATE INDEX IF NOT EXISTS idx_events_id ON public.events(id);
CREATE INDEX IF NOT EXISTS idx_audit_queue_status ON public.audit_queue(status);

-- IVF/ANN для embeddings
CREATE INDEX IF NOT EXISTS idx_embeddings_vector_ivfflat ON public.embeddings USING ivfflat (vector vector_cosine_ops) WITH (lists = 100);

-- Права доступа
ALTER TABLE public.events OWNER TO imperium;
ALTER TABLE public.audit_queue OWNER TO imperium;
ALTER TABLE public.embeddings OWNER TO imperium;

GRANT USAGE ON SCHEMA public TO api_reader, api_writer;
GRANT SELECT ON public.events, public.audit_queue, public.embeddings TO api_reader;
GRANT EXECUTE ON FUNCTION search_semantic_with_vec(vector, int) TO api_reader;
GRANT SELECT, INSERT, UPDATE ON public.events, public.audit_queue, public.embeddings TO api_writer;
GRANT EXECUTE ON FUNCTION ingest_event(jsonb, text), confirm_event(bigint, text, text), auto_audit_core(int), upsert_embedding(bigint, vector), search_semantic_with_vec(vector, int) TO api_writer;
