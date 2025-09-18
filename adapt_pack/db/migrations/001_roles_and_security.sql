-- Create enterprise roles
CREATE ROLE authenticator LOGIN NOINHERIT NOCREATEDB NOCREATEROLE NOSUPERUSER;
CREATE ROLE anonymous NOLOGIN;
CREATE ROLE llm_user NOLOGIN;
CREATE ROLE llm_admin NOLOGIN;
CREATE ROLE federation_node NOLOGIN;

-- Security check function
CREATE OR REPLACE FUNCTION api.security_check()
RETURNS void AS $$
DECLARE
    user_role text := current_setting('request.jwt.claims', true)::json->>'role';
    user_ip text := current_setting('request.headers', true)::json->>'x-forwarded-for';
    request_path text := current_setting('request.path', true);
BEGIN
    IF user_role IS NULL AND request_path NOT LIKE '/health%' THEN
        RAISE EXCEPTION 'Authentication required'
            USING HINT = 'Include valid JWT token';
    END IF;
    INSERT INTO api.security_log (user_role, ip_address, path, timestamp)
    VALUES (user_role, user_ip, request_path, NOW())
    ON CONFLICT DO NOTHING;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
