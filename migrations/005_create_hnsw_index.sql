CREATE INDEX IF NOT EXISTS idx_events_embedding_hnsw
ON events USING hnsw (embedding vector_cosine_ops);
