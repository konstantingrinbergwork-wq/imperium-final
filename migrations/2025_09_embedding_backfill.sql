-- RPC: выбрать события без эмбеддингов (id + payload)
CREATE OR REPLACE FUNCTION public.list_events_without_embedding(p_limit int DEFAULT 100)
RETURNS TABLE(id bigint, payload jsonb) LANGUAGE sql AS $$
  SELECT e.id, e.payload
  FROM public.events e
  LEFT JOIN public.embeddings emb ON emb.event_id = e.id
  WHERE emb.event_id IS NULL
  ORDER BY e.created_at
  LIMIT p_limit;
$$;

-- Grant для ролей
GRANT EXECUTE ON FUNCTION public.list_events_without_embedding(int) TO api_reader, api_writer;
