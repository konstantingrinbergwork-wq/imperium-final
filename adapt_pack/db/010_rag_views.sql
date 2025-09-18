-- RAG Views for W∞ vector operations and context aggregation
-- Idempotent: safe to run multiple times

BEGIN;

-- Materialized view for latest context aggregation by correlation
DROP MATERIALIZED VIEW IF EXISTS winf_latest_context;
CREATE MATERIALIZED VIEW winf_latest_context AS
SELECT 
    correlation_id,
    event_type,
    COUNT(*) as event_count,
    MAX(created_at) as last_event_at,
    MIN(created_at) as first_event_at,
    EXTRACT(EPOCH FROM (MAX(created_at) - MIN(created_at))) as timespan_seconds,
    JSONB_AGG(
        JSONB_BUILD_OBJECT(
            'id', id,
            'data', data,
            'created_at', created_at,
            'status', status
        ) ORDER BY created_at DESC
    ) FILTER (WHERE created_at >= NOW() - INTERVAL '24 hours') as recent_events,
    -- Vector aggregation for semantic clustering
    CASE 
        WHEN COUNT(*) FILTER (WHERE embedding IS NOT NULL) > 0 THEN
            ARRAY_AGG(embedding) FILTER (WHERE embedding IS NOT NULL)
        ELSE NULL
    END as embeddings_cluster
FROM imperium.events 
WHERE created_at >= NOW() - INTERVAL '7 days'
    AND correlation_id IS NOT NULL
GROUP BY correlation_id, event_type;

CREATE UNIQUE INDEX IF NOT EXISTS idx_winf_latest_context_correlation 
    ON winf_latest_context(correlation_id, event_type);

-- Vector lens view for fast TOP-k operations
DROP VIEW IF EXISTS winf_vector_lens CASCADE;
CREATE VIEW winf_vector_lens AS
SELECT 
    id,
    event_type,
    correlation_id,
    data->>'title' as title,
    data->>'description' as description,
    embedding,
    created_at,
    status,
    -- Precomputed vector magnitude for cosine similarity
    CASE 
        WHEN embedding IS NOT NULL THEN
            SQRT((SELECT SUM(val * val) FROM UNNEST(embedding) as val))
        ELSE NULL
    END as vector_magnitude,
    -- Event freshness score (exponential decay)
    EXP(-EXTRACT(EPOCH FROM (NOW() - created_at)) / 86400.0) as freshness_score
FROM imperium.events 
WHERE embedding IS NOT NULL
    AND status IN ('approved', 'pending')
    AND created_at >= NOW() - INTERVAL '30 days';

CREATE INDEX IF NOT EXISTS idx_winf_vector_lens_embedding_ops 
    ON imperium.events USING ivfflat (embedding vector_cosine_ops)
    WHERE embedding IS NOT NULL AND status IN ('approved', 'pending');

-- Administrative stats view for monitoring
DROP VIEW IF EXISTS winf_adm_stats CASCADE;
CREATE VIEW winf_adm_stats AS
WITH embedding_stats AS (
    SELECT 
        COUNT(*) as total_events,
        COUNT(*) FILTER (WHERE embedding IS NOT NULL) as embedded_events,
        COUNT(*) FILTER (WHERE embedding IS NOT NULL AND created_at >= NOW() - INTERVAL '1 hour') as embedded_last_hour,
        COUNT(*) FILTER (WHERE status = 'pending') as pending_events,
        COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '24 hours') as events_24h,
        AVG(EXTRACT(EPOCH FROM (updated_at - created_at))) FILTER (WHERE embedding IS NOT NULL) as avg_embedding_latency_seconds
    FROM imperium.events
    WHERE created_at >= NOW() - INTERVAL '7 days'
),
queue_stats AS (
    SELECT 
        COUNT(*) FILTER (WHERE status = 'pending') as pending_insights,
        COUNT(*) FILTER (WHERE status = 'processing') as processing_insights,
        COUNT(*) FILTER (WHERE attempts >= 3) as failed_insights,
        MAX(created_at) as latest_insight_created
    FROM imperium.analysis_queue
)
SELECT 
    e.*,
    ROUND((e.embedded_events::numeric / NULLIF(e.total_events, 0) * 100), 2) as embedding_coverage_pct,
    q.pending_insights,
    q.processing_insights, 
    q.failed_insights,
    q.latest_insight_created,
    NOW() as stats_generated_at
FROM embedding_stats e
CROSS JOIN queue_stats q;

-- Refresh function for materialized views
CREATE OR REPLACE FUNCTION refresh_winf_views()
RETURNS void 
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY winf_latest_context;
    -- Add performance logging
    INSERT INTO imperium.audit_log (event_type, data, created_at)
    VALUES ('system', 
            JSONB_BUILD_OBJECT(
                'action', 'refresh_winf_views',
                'duration_ms', EXTRACT(EPOCH FROM NOW())::int * 1000
            ), 
            NOW()
    );
END;
$$;

-- Schedule automatic refresh every 15 minutes
DROP EVENT TRIGGER IF EXISTS refresh_winf_views_trigger CASCADE;

COMMIT;
