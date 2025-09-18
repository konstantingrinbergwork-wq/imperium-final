-- Dequeue function with lease management
CREATE OR REPLACE FUNCTION queue.dequeue_job(
    p_queue_names TEXT[] DEFAULT ARRAY['default'],
    p_worker_id TEXT DEFAULT NULL,
    p_lease_duration INTERVAL DEFAULT '5 minutes',
    p_batch_size INTEGER DEFAULT 1
)
RETURNS TABLE(
    job_id UUID,
    payload JSONB,
    attempts INTEGER,
    created_at TIMESTAMPTZ
) AS $$
DECLARE
    lease_token UUID := uuid_generate_v4();
BEGIN
    RETURN QUERY
    WITH available_jobs AS (
        SELECT j.id, j.payload, j.attempts, j.created_at, j.priority
        FROM queue.jobs j
        WHERE j.status = 'pending'
          AND j.queue_name = ANY(p_queue_names)
          AND j.scheduled_at <= NOW()
          AND (j.next_retry_at IS NULL OR j.next_retry_at <= NOW())
        ORDER BY j.priority DESC, j.created_at ASC
        FOR UPDATE SKIP LOCKED
        LIMIT p_batch_size
    ),
    updated_jobs AS (
        UPDATE queue.jobs
        SET 
            status = 'processing',
            started_at = NOW(),
            lease_token = lease_token,
            lease_expires_at = NOW() + p_lease_duration,
            worker_id = p_worker_id,
            attempts = attempts + 1
        WHERE id IN (SELECT id FROM available_jobs)
        RETURNING id, payload, attempts, created_at
    )
    SELECT u.id, u.payload, u.attempts, u.created_at
    FROM updated_jobs u;
END;
$$ LANGUAGE plpgsql;
