-- Guard triggers and validation policies for data integrity
-- Idempotent: safe to run multiple times

BEGIN;

-- Vector validation function
CREATE OR REPLACE FUNCTION validate_embedding_vector(embedding_vector vector(1536))
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE STRICT
AS $$
BEGIN
    -- Check vector dimension
    IF array_length(embedding_vector, 1) != 1536 THEN
        RETURN false;
    END IF;
    
    -- Check for NaN or infinity values
    IF EXISTS (
        SELECT 1 FROM UNNEST(embedding_vector) as val 
        WHERE val = 'NaN'::float OR val = 'Infinity'::float OR val = '-Infinity'::float
    ) THEN
        RETURN false;
    END IF;
    
    -- Check vector magnitude is reasonable (not zero vector, not too large)
    DECLARE
        magnitude float;
    BEGIN
        SELECT SQRT(SUM(val * val)) INTO magnitude FROM UNNEST(embedding_vector) as val;
        IF magnitude = 0.0 OR magnitude > 100.0 THEN
            RETURN false;
        END IF;
    END;
    
    RETURN true;
END;
$$;

-- Events guard trigger function
CREATE OR REPLACE FUNCTION events_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    error_msg text;
BEGIN
    -- Validate status transitions
    IF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
        -- Valid status transitions
        IF NOT (
            (OLD.status = 'pending' AND NEW.status IN ('approved', 'rejected', 'timeout')) OR
            (OLD.status = 'approved' AND NEW.status IN ('rejected')) OR
            (OLD.status = 'rejected' AND NEW.status IN ('approved'))
        ) THEN
            RAISE EXCEPTION 'Invalid status transition from % to %', OLD.status, NEW.status;
        END IF;
    END IF;
    
    -- Validate embedding vector if present
    IF NEW.embedding IS NOT NULL THEN
        IF NOT validate_embedding_vector(NEW.embedding) THEN
            RAISE EXCEPTION 'Invalid embedding vector: dimension mismatch or invalid values';
        END IF;
    END IF;
    
    -- Validate required fields based on status
    IF NEW.status = 'approved' THEN
        IF NEW.data IS NULL OR NEW.data = '{}'::jsonb THEN
            RAISE EXCEPTION 'Approved events must have non-empty data';
        END IF;
    END IF;
    
    -- Auto-set updated_at
    IF TG_OP = 'UPDATE' THEN
        NEW.updated_at = NOW();
    END IF;
    
    -- Audit logging for status changes
    IF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO imperium.audit_log (event_type, data, created_at)
        VALUES ('status_change', 
                JSONB_BUILD_OBJECT(
                    'event_id', NEW.id,
                    'old_status', OLD.status,
                    'new_status', NEW.status,
                    'correlation_id', NEW.correlation_id
                ),
                NOW()
        );
    END IF;
    
    RETURN NEW;
END;
$$;

-- Drop and recreate trigger to ensure clean state
DROP TRIGGER IF EXISTS events_guard_trigger ON imperium.events;
CREATE TRIGGER events_guard_trigger
    BEFORE INSERT OR UPDATE ON imperium.events
    FOR EACH ROW
    EXECUTE FUNCTION events_guard();

-- Add constraint for status values (idempotent)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'events_status_check'
    ) THEN
        ALTER TABLE imperium.events 
        ADD CONSTRAINT events_status_check 
        CHECK (status IN ('pending', 'approved', 'rejected', 'timeout'));
    END IF;
END
$$;

-- Correlation ID validation
CREATE OR REPLACE FUNCTION validate_correlation_id(corr_id uuid)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE STRICT
AS $$
BEGIN
    -- Basic UUID validation (PostgreSQL handles format)
    -- Additional business logic can be added here
    RETURN corr_id IS NOT NULL;
END;
$$;

-- Index for guard operations
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_events_guard_status_updated 
    ON imperium.events(status, updated_at)
    WHERE status IN ('pending', 'processing');

-- Function to check system constraints
CREATE OR REPLACE FUNCTION check_system_constraints()
RETURNS table(constraint_name text, status text, details jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        'embedding_coverage'::text as constraint_name,
        CASE 
            WHEN (SELECT embedding_coverage_pct FROM winf_adm_stats) >= 95 THEN 'PASS'
            ELSE 'WARN'
        END as status,
        JSONB_BUILD_OBJECT(
            'current_coverage', (SELECT embedding_coverage_pct FROM winf_adm_stats),
            'threshold', 95
        ) as details
    
    UNION ALL
    
    SELECT 
        'queue_health'::text,
        CASE 
            WHEN (SELECT pending_insights FROM winf_adm_stats) <= 1000 THEN 'PASS'
            ELSE 'WARN'
        END,
        JSONB_BUILD_OBJECT(
            'pending_count', (SELECT pending_insights FROM winf_adm_stats),
            'threshold', 1000
        )
        
    UNION ALL
    
    SELECT 
        'failed_insights'::text,
        CASE 
            WHEN (SELECT failed_insights FROM winf_adm_stats) <= 50 THEN 'PASS'
            ELSE 'FAIL'
        END,
        JSONB_BUILD_OBJECT(
            'failed_count', (SELECT failed_insights FROM winf_adm_stats),
            'threshold', 50
        );
END;
$$;

COMMIT;
