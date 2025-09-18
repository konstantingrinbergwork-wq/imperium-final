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

-- Dead Letter Queue
CREATE TABLE queue.dead_letter_queue (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    original_job_id UUID NOT NULL,
    original_payload JSONB NOT NULL,
    failure_reason TEXT NOT NULL,
    failure_details JSONB DEFAULT '{}',
    original_queue TEXT NOT NULL,
    failed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    attempts_made INTEGER NOT NULL,
    final_error TEXT,
    recovery_attempted BOOLEAN DEFAULT FALSE,
    recovery_attempted_at TIMESTAMPTZ,
    recovery_successful BOOLEAN DEFAULT FALSE,
    tags JSONB DEFAULT '{}'
);

-- Fail job with retry logic
CREATE OR REPLACE FUNCTION queue.fail_job(
    p_job_id UUID,
    p_error_message TEXT,
    p_error_details JSONB DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
    job_record RECORD;
    updated_count INTEGER;
BEGIN
    SELECT * INTO job_record
    FROM queue.jobs
    WHERE id = p_job_id AND status = 'processing';
    
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;
    
    -- Check if job should be retried or moved to DLQ
    IF job_record.attempts >= job_record.max_attempts THEN
        INSERT INTO queue.dead_letter_queue (
            original_job_id, original_payload, failure_reason,
            failure_details, original_queue, attempts_made, final_error
        ) VALUES (
            p_job_id, job_record.payload, p_error_message,
            COALESCE(p_error_details, '{}'), job_record.queue_name,
            job_record.attempts, p_error_message
        );
        
        UPDATE queue.jobs
        SET status = 'dead_letter', completed_at = NOW(), last_error = p_error_message,
            lease_token = NULL, lease_expires_at = NULL
        WHERE id = p_job_id;
    ELSE
        -- Schedule for retry with exponential backoff
        UPDATE queue.jobs
        SET status = 'failed', last_error = p_error_message,
            error_count = error_count + 1,
            next_retry_at = NOW() + (retry_delay * POWER(2, LEAST(attempts, 5))),
            lease_token = NULL, lease_expires_at = NULL
        WHERE id = p_job_id;
    END IF;
    
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN updated_count > 0;
END;
$$ LANGUAGE plpgsql;
