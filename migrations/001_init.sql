-- IMPERIUM BASE MIGRATION 001
BEGIN;

-- Create roles if not exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'web_anon') THEN
        CREATE ROLE web_anon NOLOGIN;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'api_reader') THEN
        CREATE ROLE api_reader NOLOGIN;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'api_writer') THEN
        CREATE ROLE api_writer NOLOGIN;
    END IF;
END $$;

-- Grant permissions
GRANT USAGE ON SCHEMA public TO web_anon, api_reader, api_writer;

-- Create audit schema
CREATE SCHEMA IF NOT EXISTS audit;

-- Create audit table
CREATE TABLE IF NOT EXISTS audit.system_events (
    id BIGSERIAL PRIMARY KEY,
    event_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    event_type VARCHAR(50) NOT NULL,
    user_id VARCHAR(100),
    metadata JSONB
);

-- Create health_check function
CREATE OR REPLACE FUNCTION public.health_check()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    result JSON;
BEGIN
    SELECT json_build_object(
        'status', 'healthy',
        'timestamp', NOW(),
        'database', current_database(),
        'version', version()
    ) INTO result;
    
    RETURN result;
END;
$$;

-- Create system_stats function
CREATE OR REPLACE FUNCTION public.system_stats()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    result JSON;
BEGIN
    SELECT json_build_object(
        'timestamp', NOW(),
        'connections', (SELECT count(*) FROM pg_stat_activity),
        'database_size', pg_size_pretty(pg_database_size(current_database()))
    ) INTO result;
    
    RETURN result;
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION public.health_check() TO web_anon;
GRANT EXECUTE ON FUNCTION public.system_stats() TO web_anon;

COMMIT;
