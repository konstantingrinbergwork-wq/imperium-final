-- Archive and TTL management for P∞ data lifecycle
-- Idempotent: safe to run multiple times

BEGIN;

-- Archive table for old events
CREATE TABLE IF NOT EXISTS imperium.events_archive (
    LIKE imperium.events INCLUDING ALL
);

-- Archive function with configurable TTL
CREATE OR REPLACE FUNCTION archive_old_events(p_days int DEFAULT 365)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    archived_count int := 0;
    cutoff_date timestamptz;
    archive_result jsonb;
BEGIN
    cutoff_date := NOW() - (p_days || ' days')::interval;
    
    -- Move old events to archive
    WITH archived AS (
        DELETE FROM imperium.events 
        WHERE created_at < cutoff_date
            AND status IN ('approved', 'rejected', 'timeout')
            AND id NOT IN (
                -- Keep events that have recent related activity
                SELECT DISTINCT e.id 
                FROM imperium.events e
                JOIN imperium.analysis_queue aq ON aq.payload->>'event_id' = e.id::text
                WHERE aq.created_at > cutoff_date
            )
        RETURNING *
    ),
    inserted AS (
        INSERT INTO imperium.events_archive 
        SELECT * FROM archived
        RETURNING id
    )
    SELECT COUNT(*) INTO archived_count FROM inserted;
    
    -- Log the archival operation
    archive_result := JSONB_BUILD_OBJECT(
        'archived_count', archived_count,
        'cutoff_date', cutoff_date,
        'retention_days', p_days,
        'archived_at', NOW()
    );
    
    INSERT INTO imperium.audit_log (event_type, data, created_at)
    VALUES ('archive_operation', archive_result, NOW());
    
    -- Try to set up partitioning if pg_partman is available
    -- This will silently skip if extension doesn't exist
    BEGIN
        -- Check if pg_partman extension exists
        IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_partman') THEN
            -- Set up monthly partitioning for events table
            PERFORM partman.create_parent(
                p_parent_table => 'imperium.events',
                p_control => 'created_at',
                p_type => 'range',
                p_interval => 'monthly',
                p_premake => 3
            );
            
            -- Update archive result with partitioning info
            archive_result := archive_result || JSONB_BUILD_OBJECT('partitioning', 'enabled');
        ELSE
            archive_result := archive_result || JSONB_BUILD_OBJECT('partitioning', 'pg_partman not available');
        END IF;
    EXCEPTION 
        WHEN OTHERS THEN
            -- Partitioning failed, but continue
            archive_result := archive_result || JSONB_BUILD_OBJECT(
                'partitioning', 'failed',
                'partition_error', SQLERRM
            );
    END;
    
    RETURN archive_result;
END;
$$;

-- Cleanup archive function (for very old data)
CREATE OR REPLACE FUNCTION cleanup_archive(p_archive_days int DEFAULT 2555) -- ~7 years
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    deleted_count int := 0;
BEGIN
    DELETE FROM imperium.events_archive
    WHERE created_at < NOW() - (p_archive_days || ' days')::interval;
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    
    INSERT INTO imperium.audit_log (event_type, data, created_at)
    VALUES ('archive_cleanup', 
            JSONB_BUILD_OBJECT(
                'deleted_count', deleted_count,
                'retention_years', ROUND(p_archive_days::numeric / 365, 1)
            ), 
            NOW());
    
    RETURN deleted_count;
END;
$$;

-- Index on archive table for efficient queries
CREATE INDEX IF NOT EXISTS idx_events_archive_created_at 
    ON imperium.events_archive(created_at);
CREATE INDEX IF NOT EXISTS idx_events_archive_correlation 
    ON imperium.events_archive(correlation_id);

-- View combining live and archived data
CREATE OR REPLACE VIEW imperium.events_full AS
SELECT *, false as is_archived FROM imperium.events
UNION ALL
SELECT *, true as is_archived FROM imperium.events_archive;

-- Grant permissions for archive operations
GRANT EXECUTE ON FUNCTION archive_old_events(int) TO api_writer;
GRANT EXECUTE ON FUNCTION cleanup_archive(int) TO api_admin;
GRANT SELECT ON imperium.events_archive TO api_reader;
GRANT SELECT ON imperium.events_full TO api_reader;

-- Schedule weekly archival (this would typically be handled by cron or systemd timer)
CREATE OR REPLACE FUNCTION schedule_archive_maintenance()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    -- This function can be called by external scheduler
    PERFORM archive_old_events(365);
    PERFORM cleanup_archive(2555);
END;
$$;

COMMIT;
