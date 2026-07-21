
-- ============================================================
-- BuildBud Database Initialization
-- ============================================================
-- Extensions
-- [self-host] The schema below is a Supabase pg_dump: it references
-- extensions.uuid_generate_v4() and FKs public.sessions -> auth.users. On plain
-- Postgres those schemas do not exist, so create them (and install the extensions
-- INTO the extensions schema) before the dump body, or init aborts and the DB is
-- left EMPTY while pg_isready still reports healthy.
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "pgcrypto" SCHEMA extensions;
GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;

-- Self-host uses app-token auth (ENABLE_AUTH=true), not Supabase Auth. Stub
-- auth.users so the vestigial public.sessions.user_id FK resolves at init time.
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE IF NOT EXISTS auth.users (id uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4());
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

-- PostgREST roles
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator LOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN BYPASSRLS;
  END IF;
END $$;

GRANT anon        TO authenticator;
GRANT authenticated TO authenticator;
GRANT service_role  TO authenticator;

-- Set authenticator password to match POSTGRES_PASSWORD
-- (handled by docker-entrypoint via POSTGRES_PASSWORD env var going to postgres user;
--  authenticator uses same password since it connects via docker network only)
--
-- PostgreSQL database dump
--

-- Dumped from database version 15.8
-- Dumped by pg_dump version 15.8

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', 'public', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--



--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: artifact_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.artifact_type AS ENUM (
    'diff',
    'patch',
    'stdout',
    'stderr',
    'test_output',
    'screenshot'
);


--
-- Name: attempt_exec_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.attempt_exec_status AS ENUM (
    'started',
    'executed',
    'failed_exec'
);


--
-- Name: attempt_verify_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.attempt_verify_status AS ENUM (
    'pending',
    'pre_checked',
    'failed_check',
    'reviewed',
    'failed_review'
);


--
-- Name: execution_mode; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.execution_mode AS ENUM (
    'daemon',
    'cloud_byok'
);


--
-- Name: log_level; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.log_level AS ENUM (
    'info',
    'warn',
    'error'
);


--
-- Name: machine_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.machine_status AS ENUM (
    'online',
    'offline',
    'busy',
    'stale'
);


--
-- Name: plan_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.plan_status AS ENUM (
    'draft',
    'active',
    'paused',
    'complete',
    'failed'
);


--
-- Name: task_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.task_status AS ENUM (
    'planned',
    'dispatched',
    'executing',
    'executed',
    'verifying',
    'passed',
    'done',
    'failed',
    'retrying',
    'blocked'
);


--
-- Name: auto_protect_coder_project(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.auto_protect_coder_project() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.environment = 'coder' THEN
        INSERT INTO protected_resources (env, resource_type, resource_id, reason)
        VALUES ('coder', 'project', NEW.id, 'Auto-protected CODER project')
        ON CONFLICT (env, resource_type, resource_id) DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: auto_protect_coder_resource(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.auto_protect_coder_resource() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.env = 'coder' THEN
        INSERT INTO protected_resources (env, resource_type, resource_id, reason)
        VALUES ('coder', TG_ARGV[0], NEW.id, 'Auto-protected CODER resource')
        ON CONFLICT (env, resource_type, resource_id) DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: check_project_env_consistency(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_project_env_consistency() RETURNS trigger
    LANGUAGE plpgsql
    AS $$DECLARE parent_env TEXT; BEGIN SELECT environment INTO parent_env FROM projects WHERE id = NEW.project_id; IF parent_env IS NOT NULL AND NEW.environment <> parent_env THEN RAISE EXCEPTION 'Environment mismatch: child row has %, parent project has %', NEW.environment, parent_env; END IF; RETURN NEW; END;$$;


--
-- Name: claim_node_atomic(uuid, character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_node_atomic(p_node_id uuid, p_claim_token_hash character varying, p_machine_id character varying, p_netbird_peer_id character varying, p_node_secret_hash character varying) RETURNS TABLE(node_id uuid, network_id uuid, hostname character varying, ip_address inet, claimed boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_node RECORD;
BEGIN
  -- Atomic claim: validate token + machine_id + update in one statement
  UPDATE network_nodes n
  SET
    claim_token_used = true,
    node_secret_hash = p_node_secret_hash,
    netbird_peer_id = p_netbird_peer_id,
    status = 'online',
    last_seen_at = NOW(),
    updated_at = NOW()
  WHERE n.id = p_node_id
    AND n.claim_token_hash = p_claim_token_hash
    AND n.claim_token_used = false
    AND n.claim_token_expires_at > NOW()
    AND (n.machine_id IS NULL OR n.machine_id = p_machine_id)
  RETURNING n.id, n.network_id, n.hostname, n.ip_address
  INTO v_node;

  IF NOT FOUND THEN
    -- Claim failed: invalid token, already used, expired, or machine_id mismatch
    RETURN QUERY SELECT NULL::UUID, NULL::UUID, NULL::VARCHAR(255), NULL::INET, false;
    RETURN;
  END IF;

  RETURN QUERY SELECT v_node.id, v_node.network_id, v_node.hostname,
                      v_node.ip_address, true;
END;
$$;


--
-- Name: FUNCTION claim_node_atomic(p_node_id uuid, p_claim_token_hash character varying, p_machine_id character varying, p_netbird_peer_id character varying, p_node_secret_hash character varying); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.claim_node_atomic(p_node_id uuid, p_claim_token_hash character varying, p_machine_id character varying, p_netbird_peer_id character varying, p_node_secret_hash character varying) IS 'Atomic node claim. Validates claim token, sets node_secret, activates node.';


--
-- Name: cleanup_event_outbox(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cleanup_event_outbox(days_old integer DEFAULT 7) RETURNS integer
    LANGUAGE plpgsql
    AS $$ DECLARE deleted_count INT; BEGIN DELETE FROM event_outbox WHERE (status IN ('published', 'processed_local') AND created_at < NOW() - (days_old || ' days')::INTERVAL) OR (status = 'failed' AND attempts >= 10 AND created_at < NOW() - (days_old || ' days')::INTERVAL); GET DIAGNOSTICS deleted_count = ROW_COUNT; RETURN deleted_count; END; $$;


--
-- Name: cleanup_expired_sessions(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cleanup_expired_sessions() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  deleted_count INTEGER;
BEGIN
  DELETE FROM public.sessions
  WHERE refresh_expires_at < NOW()
     OR (revoked = TRUE AND revoked_at < NOW() - INTERVAL '24 hours');
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$;


--
-- Name: consume_join_token(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.consume_join_token(p_token_hash text) RETURNS TABLE(id uuid, network_id uuid, name text, uses integer, max_uses integer, expires_at timestamp with time zone, created_by uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  UPDATE network_join_tokens t
  SET uses = t.uses + 1
  WHERE t.token_hash = p_token_hash
    AND (t.revoked IS NULL OR t.revoked = false)
    AND t.expires_at > NOW()
    AND t.uses < t.max_uses
  RETURNING t.id, t.network_id, t.name, t.uses, t.max_uses, t.expires_at, t.created_by;
END;
$$;


--
-- Name: execute_sql(text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.execute_sql(query text, read_only boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$ DECLARE result jsonb; BEGIN EXECUTE 'SELECT COALESCE(jsonb_agg(t), ''[]''::jsonb) FROM (' || query || ') t' INTO result; RETURN result; EXCEPTION WHEN others THEN RAISE EXCEPTION 'Error executing SQL (SQLSTATE: %): %', SQLSTATE, SQLERRM; END; $$;


--
-- Name: find_or_create_node(uuid, character varying, character varying, inet, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.find_or_create_node(p_network_id uuid, p_hostname character varying, p_machine_id character varying, p_ip_address inet, p_role character varying) RETURNS TABLE(id uuid, network_id uuid, hostname character varying, machine_id character varying, ip_address inet, status character varying, is_existing boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_node RECORD;
  v_is_existing BOOLEAN := false;
BEGIN
  -- Try to find by machine_id first (more durable identity)
  IF p_machine_id IS NOT NULL THEN
    SELECT * INTO v_node
    FROM network_nodes n
    WHERE n.network_id = p_network_id
      AND n.machine_id = p_machine_id;

    IF FOUND THEN
      v_is_existing := true;
      -- Update hostname if changed
      IF v_node.hostname != p_hostname THEN
        UPDATE network_nodes
        SET hostname = p_hostname, updated_at = NOW()
        WHERE network_nodes.id = v_node.id;
        v_node.hostname := p_hostname;
      END IF;

      RETURN QUERY SELECT v_node.id, v_node.network_id, v_node.hostname,
                          v_node.machine_id, v_node.ip_address, v_node.status, v_is_existing;
      RETURN;
    END IF;
  END IF;

  -- Try to find by hostname (fallback for legacy nodes without machine_id)
  SELECT * INTO v_node
  FROM network_nodes n
  WHERE n.network_id = p_network_id
    AND n.hostname = p_hostname
    AND n.machine_id IS NULL;

  IF FOUND THEN
    v_is_existing := true;
    -- Update machine_id now that we have it
    IF p_machine_id IS NOT NULL THEN
      UPDATE network_nodes
      SET machine_id = p_machine_id, updated_at = NOW()
      WHERE network_nodes.id = v_node.id;
      v_node.machine_id := p_machine_id;
    END IF;

    RETURN QUERY SELECT v_node.id, v_node.network_id, v_node.hostname,
                        v_node.machine_id, v_node.ip_address, v_node.status, v_is_existing;
    RETURN;
  END IF;

  -- Create new node
  INSERT INTO network_nodes (network_id, hostname, machine_id, ip_address, role, status, labels)
  VALUES (p_network_id, p_hostname, p_machine_id, p_ip_address, p_role, 'pending', '{}')
  RETURNING network_nodes.id, network_nodes.network_id, network_nodes.hostname,
            network_nodes.machine_id, network_nodes.ip_address, network_nodes.status
  INTO v_node;

  v_is_existing := false;
  RETURN QUERY SELECT v_node.id, v_node.network_id, v_node.hostname,
                      v_node.machine_id, v_node.ip_address, v_node.status, v_is_existing;
END;
$$;


--
-- Name: join_network_atomic(text, uuid, character varying, character varying, inet, character varying, character varying, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.join_network_atomic(p_token_hash text, p_network_id uuid, p_hostname character varying, p_machine_id character varying, p_ip_address inet, p_role character varying, p_claim_token_hash character varying, p_claim_token_expires_at timestamp with time zone) RETURNS TABLE(node_id uuid, network_id uuid, hostname character varying, machine_id character varying, ip_address inet, status character varying, is_rejoin boolean, token_consumed boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_node RECORD;
  v_is_rejoin BOOLEAN := false;
  v_token_consumed BOOLEAN := false;
  v_token_valid BOOLEAN := false;
BEGIN
  -- Step 1: Check if this is a rejoin by machine_id
  IF p_machine_id IS NOT NULL THEN
    SELECT * INTO v_node
    FROM network_nodes n
    WHERE n.network_id = p_network_id
      AND n.machine_id = p_machine_id;

    IF FOUND THEN
      v_is_rejoin := true;
      -- Update hostname if changed, set new claim token
      UPDATE network_nodes
      SET hostname = p_hostname,
          claim_token_hash = p_claim_token_hash,
          claim_token_expires_at = p_claim_token_expires_at,
          claim_token_used = false,
          updated_at = NOW()
      WHERE network_nodes.id = v_node.id;

      RETURN QUERY SELECT v_node.id, v_node.network_id, p_hostname,
                          v_node.machine_id, v_node.ip_address, v_node.status,
                          v_is_rejoin, v_token_consumed;
      RETURN;
    END IF;
  END IF;

  -- Step 2: Check if hostname matches node without machine_id (legacy upgrade)
  SELECT * INTO v_node
  FROM network_nodes n
  WHERE n.network_id = p_network_id
    AND n.hostname = p_hostname
    AND n.machine_id IS NULL;

  IF FOUND THEN
    v_is_rejoin := true;
    -- Upgrade: add machine_id and new claim token
    UPDATE network_nodes
    SET machine_id = p_machine_id,
        claim_token_hash = p_claim_token_hash,
        claim_token_expires_at = p_claim_token_expires_at,
        claim_token_used = false,
        updated_at = NOW()
    WHERE network_nodes.id = v_node.id;

    RETURN QUERY SELECT v_node.id, v_node.network_id, v_node.hostname,
                        p_machine_id, v_node.ip_address, v_node.status,
                        v_is_rejoin, v_token_consumed;
    RETURN;
  END IF;

  -- Step 3: New join - consume token atomically
  UPDATE network_join_tokens t
  SET uses = t.uses + 1
  WHERE t.token_hash = p_token_hash
    AND t.network_id = p_network_id
    AND (t.revoked IS NULL OR t.revoked = false)
    AND t.expires_at > NOW()
    AND t.uses < t.max_uses
  RETURNING true INTO v_token_valid;

  IF NOT v_token_valid THEN
    -- Token invalid/expired/exhausted
    RETURN;
  END IF;

  v_token_consumed := true;

  -- Step 4: Create new node
  INSERT INTO network_nodes (
    network_id, hostname, machine_id, ip_address, role, status, labels,
    claim_token_hash, claim_token_expires_at, claim_token_used
  )
  VALUES (
    p_network_id, p_hostname, p_machine_id, p_ip_address, p_role, 'pending', '{}',
    p_claim_token_hash, p_claim_token_expires_at, false
  )
  RETURNING network_nodes.id, network_nodes.network_id, network_nodes.hostname,
            network_nodes.machine_id, network_nodes.ip_address, network_nodes.status
  INTO v_node;

  RETURN QUERY SELECT v_node.id, v_node.network_id, v_node.hostname,
                      v_node.machine_id, v_node.ip_address, v_node.status,
                      v_is_rejoin, v_token_consumed;
END;
$$;


--
-- Name: FUNCTION join_network_atomic(p_token_hash text, p_network_id uuid, p_hostname character varying, p_machine_id character varying, p_ip_address inet, p_role character varying, p_claim_token_hash character varying, p_claim_token_expires_at timestamp with time zone); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.join_network_atomic(p_token_hash text, p_network_id uuid, p_hostname character varying, p_machine_id character varying, p_ip_address inet, p_role character varying, p_claim_token_hash character varying, p_claim_token_expires_at timestamp with time zone) IS 'Atomic network join. Rejoin (same machine_id) is FREE and does not consume token.';


--
-- Name: node_heartbeat(uuid, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.node_heartbeat(p_node_id uuid, p_node_secret_hash character varying, p_machine_id character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_updated BOOLEAN;
BEGIN
  UPDATE network_nodes n
  SET last_seen_at = NOW()
  WHERE n.id = p_node_id
    AND n.node_secret_hash = p_node_secret_hash
    AND n.machine_id = p_machine_id
    AND n.status IN ('online', 'offline')
  RETURNING true INTO v_updated;

  -- Also update status to online if was offline
  IF v_updated THEN
    UPDATE network_nodes
    SET status = 'online'
    WHERE id = p_node_id AND status = 'offline';
  END IF;

  RETURN COALESCE(v_updated, false);
END;
$$;


--
-- Name: FUNCTION node_heartbeat(p_node_id uuid, p_node_secret_hash character varying, p_machine_id character varying); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.node_heartbeat(p_node_id uuid, p_node_secret_hash character varying, p_machine_id character varying) IS 'Node heartbeat. Validates node_secret and updates last_seen.';


--
-- Name: prevent_project_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_project_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM protected_resources
        WHERE resource_id = OLD.id
        AND env = OLD.environment
    ) THEN
        RAISE EXCEPTION 'Cannot delete protected project: % (env: %)', OLD.id, OLD.environment;
    END IF;
    RETURN OLD;
END;
$$;


--
-- Name: prevent_project_env_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_project_env_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$BEGIN IF OLD.environment IS NOT NULL AND NEW.environment <> OLD.environment THEN RAISE EXCEPTION 'Cannot change project environment from % to %', OLD.environment, NEW.environment; END IF; RETURN NEW; END;$$;


--
-- Name: prevent_protected_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_protected_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM protected_resources
        WHERE resource_id = OLD.id
        AND env = OLD.env
    ) THEN
        RAISE EXCEPTION 'Cannot delete protected resource: % (type: %, env: %)', OLD.id, TG_ARGV[0], OLD.env;
    END IF;
    RETURN OLD;
END;
$$;


--
-- Name: update_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ BEGIN NEW.updated_at = NOW(); RETURN NEW; END; $$;


--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: agents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agents (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    name character varying(255) NOT NULL,
    project_id uuid,
    hostname character varying(255),
    status character varying(50) DEFAULT 'offline'::character varying,
    last_seen_at timestamp with time zone,
    capabilities jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: app_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    env text NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT app_settings_env_check CHECK ((env = ANY (ARRAY['dev'::text, 'coder'::text, 'prod'::text, 'user'::text, 'test'::text])))
);


--
-- Name: credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.credentials (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    env text NOT NULL,
    provider text NOT NULL,
    name text DEFAULT 'default'::text NOT NULL,
    encrypted_value text NOT NULL,
    iv text NOT NULL,
    auth_tag text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT credentials_env_check CHECK ((env = ANY (ARRAY['dev'::text, 'coder'::text, 'prod'::text, 'user'::text, 'test'::text])))
);


--
-- Name: dlq_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dlq_messages (
    id text NOT NULL,
    environment text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    handler text NOT NULL,
    category text NOT NULL,
    original_subject text NOT NULL,
    original_stream text,
    original_consumer text,
    attempts integer DEFAULT 0 NOT NULL,
    first_seen_at timestamp with time zone NOT NULL,
    last_error text NOT NULL,
    last_error_at timestamp with time zone NOT NULL,
    payload jsonb NOT NULL,
    headers jsonb,
    status text DEFAULT 'open'::text NOT NULL,
    status_reason text,
    status_changed_at timestamp with time zone,
    CONSTRAINT dlq_messages_environment_check CHECK ((environment = ANY (ARRAY['dev'::text, 'prod'::text, 'coder'::text, 'user'::text]))),
    CONSTRAINT dlq_messages_status_check CHECK ((status = ANY (ARRAY['open'::text, 'requeued'::text, 'dropped'::text])))
);


--
-- Name: event_outbox; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_outbox (
    id text NOT NULL,
    event_type text NOT NULL,
    subject text NOT NULL,
    payload jsonb NOT NULL,
    status text DEFAULT 'pending'::text,
    attempts integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    published_at timestamp with time zone,
    processed_at timestamp with time zone,
    last_error text,
    environment text NOT NULL,
    CONSTRAINT event_outbox_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'published'::text, 'processed_local'::text, 'failed'::text])))
);


--
-- Name: event_receipts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_receipts (
    idempotency_key text NOT NULL,
    event_type text NOT NULL,
    handler text NOT NULL,
    status text DEFAULT 'started'::text,
    result_ref text,
    processed_at timestamp with time zone DEFAULT now(),
    completed_at timestamp with time zone,
    error_message text,
    environment text NOT NULL,
    CONSTRAINT event_receipts_status_check CHECK ((status = ANY (ARRAY['started'::text, 'completed'::text, 'failed'::text])))
);


--
-- Name: execution_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.execution_evidence (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    task_id uuid NOT NULL,
    attempt_number integer DEFAULT 1 NOT NULL,
    diff text,
    files_changed text[],
    logs_excerpt text,
    turn_count integer,
    cost_usd numeric(10,4),
    duration_ms bigint,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: generated_specs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.generated_specs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    source text DEFAULT 'autonomy'::text NOT NULL,
    trigger_type text DEFAULT 'recovery'::text NOT NULL,
    trigger_id uuid,
    title text NOT NULL,
    description text NOT NULL,
    acceptance_criteria jsonb DEFAULT '[]'::jsonb,
    affected_files jsonb DEFAULT '[]'::jsonb,
    complexity text DEFAULT 'simple'::text,
    fix_confidence real DEFAULT 0.5,
    status text DEFAULT 'pending'::text NOT NULL,
    branch_name text,
    pr_url text,
    created_at timestamp with time zone DEFAULT now(),
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    failure_signature text,
    correlation_id text,
    pr_number integer,
    pr_draft boolean DEFAULT true,
    environment text DEFAULT 'dev'::text NOT NULL,
    CONSTRAINT chk_generated_specs_env CHECK ((environment = ANY (ARRAY['dev'::text, 'prod'::text, 'coder'::text, 'user'::text])))
);


--
-- Name: integration_scans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.integration_scans (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    machine_id uuid,
    scanner text NOT NULL,
    trigger text DEFAULT 'manual'::text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    scan_scope text DEFAULT 'full'::text NOT NULL,
    tool_version text,
    db_version text,
    git_commit_sha text,
    target_paths jsonb DEFAULT '[]'::jsonb,
    scanner_flags text[],
    summary jsonb DEFAULT '{}'::jsonb,
    findings jsonb DEFAULT '[]'::jsonb,
    error text,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    duration_ms bigint,
    environment text DEFAULT 'dev'::text,
    created_at timestamp with time zone DEFAULT now(),
    triggered_by_task_id uuid,
    CONSTRAINT integration_scans_scan_scope_check CHECK ((scan_scope = ANY (ARRAY['full'::text, 'latest-commit'::text, 'lockfile'::text]))),
    CONSTRAINT integration_scans_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'running'::text, 'completed'::text, 'failed'::text]))),
    CONSTRAINT integration_scans_trigger_check CHECK ((trigger = ANY (ARRAY['manual'::text, 'post_task'::text, 'scheduled'::text])))
);


--
-- Name: machine_manifests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.machine_manifests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    machine_id uuid NOT NULL,
    project_id uuid NOT NULL,
    file_tree_hash text,
    dependency_files jsonb DEFAULT '{}'::jsonb,
    recent_commits jsonb DEFAULT '[]'::jsonb,
    branch text,
    total_files integer DEFAULT 0,
    pushed_at timestamp with time zone DEFAULT now()
);


--
-- Name: TABLE machine_manifests; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.machine_manifests IS 'T3.5: Repo context manifests pushed by daemon';


--
-- Name: machines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.machines (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    nkey_public text,
    execution_mode public.execution_mode DEFAULT 'daemon'::public.execution_mode NOT NULL,
    status public.machine_status DEFAULT 'offline'::public.machine_status,
    last_heartbeat timestamp with time zone,
    system_info jsonb DEFAULT '{}'::jsonb,
    max_concurrent integer DEFAULT 1,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    owner_id uuid,
    environment text DEFAULT 'dev'::text NOT NULL
);


--
-- Name: TABLE machines; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.machines IS 'T3.2: Registered executor machines (daemon or cloud BYOK)';


--
-- Name: network_audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.network_audit_log (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    network_id uuid,
    project_id uuid,
    event_type character varying(50) NOT NULL,
    actor_id uuid,
    actor_type character varying(20),
    details jsonb DEFAULT '{}'::jsonb,
    ip_address inet,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT network_audit_log_actor_type_check CHECK (((actor_type)::text = ANY ((ARRAY['user'::character varying, 'agent'::character varying, 'system'::character varying])::text[])))
);


--
-- Name: TABLE network_audit_log; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.network_audit_log IS 'Audit trail for all network-related events';


--
-- Name: network_join_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.network_join_tokens (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    network_id uuid NOT NULL,
    token character varying(64) NOT NULL,
    token_hash character varying(128),
    name character varying(255),
    expires_at timestamp with time zone NOT NULL,
    max_uses integer DEFAULT 1,
    uses integer DEFAULT 0,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    revoked boolean DEFAULT false
);


--
-- Name: TABLE network_join_tokens; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.network_join_tokens IS 'Cross-environment by design: tokens work across environments';


--
-- Name: network_nodes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.network_nodes (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    network_id uuid NOT NULL,
    agent_id uuid,
    netbird_peer_id character varying(255),
    hostname character varying(255) NOT NULL,
    ip_address inet,
    public_ip inet,
    status character varying(20) DEFAULT 'pending'::character varying,
    role character varying(50),
    labels jsonb DEFAULT '{}'::jsonb,
    last_seen_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    machine_id character varying(255),
    claim_token_hash character varying(64),
    claim_token_expires_at timestamp with time zone,
    claim_token_used boolean DEFAULT false,
    node_secret_hash character varying(64),
    CONSTRAINT network_nodes_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'online'::character varying, 'offline'::character varying, 'error'::character varying])::text[])))
);


--
-- Name: TABLE network_nodes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.network_nodes IS 'Cross-environment by design: nodes can serve any environment';


--
-- Name: COLUMN network_nodes.claim_token_hash; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.network_nodes.claim_token_hash IS 'SHA-256 hash of claim token (10 min TTL, single-use).';


--
-- Name: COLUMN network_nodes.node_secret_hash; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.network_nodes.node_secret_hash IS 'SHA-256 hash of node secret for heartbeat auth.';


--
-- Name: networks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.networks (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    project_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    netbird_network_id character varying(255),
    cidr character varying(18) DEFAULT '100.64.0.0/10'::character varying,
    status character varying(20) DEFAULT 'active'::character varying,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT networks_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'disabled'::character varying, 'deleted'::character varying])::text[])))
);


--
-- Name: TABLE networks; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.networks IS 'Cross-environment by design: networks span all environments';


--
-- Name: plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plans (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    name text NOT NULL,
    description text,
    status public.plan_status DEFAULT 'draft'::public.plan_status,
    phases jsonb DEFAULT '[]'::jsonb NOT NULL,
    execution_mode public.execution_mode DEFAULT 'cloud_byok'::public.execution_mode NOT NULL,
    machine_id uuid,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    completed_at timestamp with time zone,
    environment text DEFAULT 'dev'::text NOT NULL,
    intent text,
    author_type text DEFAULT 'human'::text,
    total_cost_usd numeric(10,4) DEFAULT 0,
    total_duration_ms bigint DEFAULT 0,
    failure_budget jsonb DEFAULT '{"max_retries": 3, "max_cost_usd": 5, "max_duration_ms": 7200000}'::jsonb,
    rendered_markdown text
);


--
-- Name: TABLE plans; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.plans IS 'T3.2: Execution plans decomposed into phases and tasks';


--
-- Name: project_components; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.project_components (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    name text NOT NULL,
    type text,
    node_ref text,
    node_id uuid,
    remote_path text,
    build_commands jsonb DEFAULT '[]'::jsonb,
    deploy_commands jsonb DEFAULT '[]'::jsonb,
    deploy_status text DEFAULT 'never'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: project_connections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.project_connections (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    connection_type text NOT NULL,
    status text DEFAULT 'unverified'::text,
    local_path text,
    remote_host text,
    remote_ssh_port integer DEFAULT 22322,
    remote_ssh_user text DEFAULT 'bb-daemon'::text,
    remote_project_path text,
    machine_id uuid,
    git_remote_url text,
    git_branch text DEFAULT 'main'::text,
    last_verified_at timestamp with time zone,
    verification_results jsonb,
    error_message text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT project_connections_connection_type_check CHECK ((connection_type = ANY (ARRAY['local'::text, 'remote_vps'::text, 'cloud_byok'::text]))),
    CONSTRAINT project_connections_status_check CHECK ((status = ANY (ARRAY['unverified'::text, 'verified'::text, 'installing'::text, 'waiting_heartbeat'::text, 'connected'::text, 'error'::text, 'disconnected'::text])))
);


--
-- Name: project_deployments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.project_deployments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    machine_id uuid NOT NULL,
    execution_mode text DEFAULT 'cloud_byok'::text NOT NULL,
    status text DEFAULT 'active'::text,
    last_cleanup_stage integer DEFAULT 0,
    install_manifest jsonb DEFAULT '{}'::jsonb,
    current_inventory jsonb DEFAULT '{}'::jsonb,
    installed_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    environment text DEFAULT 'dev'::text NOT NULL
);


--
-- Name: project_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.project_links (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    source_project_id uuid NOT NULL,
    target_project_id uuid NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying,
    policy jsonb DEFAULT '{}'::jsonb,
    message text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    accepted_at timestamp with time zone,
    accepted_by uuid,
    CONSTRAINT project_links_check CHECK ((source_project_id <> target_project_id)),
    CONSTRAINT project_links_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'active'::character varying, 'revoked'::character varying])::text[])))
);


--
-- Name: TABLE project_links; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.project_links IS 'Selective peering relationships between project networks';


--
-- Name: projects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.projects (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    owner_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    controller_id uuid,
    path text,
    config jsonb DEFAULT '{}'::jsonb,
    config_hash text,
    status text DEFAULT 'active'::text,
    last_scanned_at timestamp with time zone,
    stack jsonb DEFAULT '{}'::jsonb,
    verify_config jsonb DEFAULT '{}'::jsonb,
    health jsonb DEFAULT '{"status": "unknown"}'::jsonb,
    settings jsonb DEFAULT '{}'::jsonb,
    environment text DEFAULT 'dev'::text NOT NULL,
    slug text,
    visibility text DEFAULT 'shared'::text NOT NULL,
    created_by uuid,
    CONSTRAINT chk_projects_env CHECK ((environment = ANY (ARRAY['dev'::text, 'prod'::text, 'coder'::text, 'user'::text])))
);


--
-- Name: protected_resources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.protected_resources (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    env text NOT NULL,
    resource_type text NOT NULL,
    resource_id uuid NOT NULL,
    protected_at timestamp with time zone DEFAULT now() NOT NULL,
    reason text,
    CONSTRAINT protected_resources_env_check CHECK ((env = ANY (ARRAY['dev'::text, 'coder'::text, 'prod'::text, 'user'::text, 'test'::text]))),
    CONSTRAINT protected_resources_type_check CHECK ((resource_type = ANY (ARRAY['credential'::text, 'project'::text, 'setting'::text, 'session'::text])))
);


--
-- Name: rate_limits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rate_limits (
    key text NOT NULL,
    env text NOT NULL,
    count integer DEFAULT 1 NOT NULL,
    first_attempt timestamp with time zone DEFAULT now() NOT NULL,
    blocked boolean DEFAULT false NOT NULL,
    blocked_until timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT rate_limits_env_check CHECK ((env = ANY (ARRAY['dev'::text, 'coder'::text, 'prod'::text, 'user'::text, 'test'::text])))
);


--
-- Name: recovery_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recovery_attempts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    verification_run_id uuid NOT NULL,
    spec_id uuid,
    attempt_number integer DEFAULT 1 NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    failure_summary jsonb DEFAULT '[]'::jsonb,
    fix_approach text,
    changes_made jsonb DEFAULT '[]'::jsonb,
    verification_result_id uuid,
    failure_reason text,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    duration_ms integer,
    created_at timestamp with time zone DEFAULT now(),
    correlation_id text,
    escalated boolean DEFAULT false,
    escalation_reason text,
    environment text DEFAULT 'dev'::text NOT NULL,
    CONSTRAINT chk_recovery_attempts_env CHECK ((environment = ANY (ARRAY['dev'::text, 'prod'::text, 'coder'::text, 'user'::text])))
);


--
-- Name: sentry_issues; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sentry_issues (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    project_id uuid NOT NULL,
    sentry_issue_id text NOT NULL,
    sentry_project_slug text,
    sentry_project_id bigint,
    title text NOT NULL,
    culprit text,
    level text DEFAULT 'error'::text,
    status text DEFAULT 'unresolved'::text,
    first_seen timestamp with time zone,
    last_seen timestamp with time zone,
    event_count integer DEFAULT 0,
    user_count integer DEFAULT 0,
    short_id text,
    permalink text,
    metadata jsonb DEFAULT '{}'::jsonb,
    buildbud_task_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    access_token_hash text NOT NULL,
    refresh_token_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    refresh_expires_at timestamp with time zone NOT NULL,
    user_id uuid,
    environment text NOT NULL,
    ip_address inet,
    user_agent text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_used_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked boolean DEFAULT false NOT NULL,
    revoked_at timestamp with time zone,
    revoked_reason text,
    auth_method text DEFAULT 'password'::text,
    CONSTRAINT sessions_environment_check CHECK ((environment = ANY (ARRAY['dev'::text, 'coder'::text, 'prod'::text, 'user'::text])))
);


--
-- Name: task_artifacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_artifacts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    attempt_id uuid NOT NULL,
    artifact_type public.artifact_type NOT NULL,
    storage_ref text NOT NULL,
    size_bytes integer DEFAULT 0,
    content_preview text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: TABLE task_artifacts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.task_artifacts IS 'T3.2: Typed artifact references for execution outputs';


--
-- Name: task_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_attempts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    task_id uuid NOT NULL,
    attempt_number integer NOT NULL,
    dispatch_id uuid NOT NULL,
    machine_id uuid,
    execution_status public.attempt_exec_status DEFAULT 'started'::public.attempt_exec_status,
    verification_status public.attempt_verify_status DEFAULT 'pending'::public.attempt_verify_status,
    branch text,
    worktree_path text,
    commit_sha_before text,
    commit_sha_after text,
    exit_code integer,
    agent_summary text,
    pre_check_results jsonb,
    post_review_results jsonb,
    failure_context text,
    diff_size_bytes integer DEFAULT 0,
    stdout_size_bytes integer DEFAULT 0,
    stderr_size_bytes integer DEFAULT 0,
    started_at timestamp with time zone DEFAULT now(),
    completed_at timestamp with time zone,
    duration_seconds integer,
    environment text DEFAULT 'dev'::text NOT NULL
);


--
-- Name: TABLE task_attempts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.task_attempts IS 'T3.2: Per-attempt execution ledger with idempotency';


--
-- Name: task_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    task_id uuid NOT NULL,
    attempt_number integer,
    "timestamp" timestamp with time zone DEFAULT now(),
    level public.log_level DEFAULT 'info'::public.log_level,
    message text NOT NULL,
    metadata jsonb
);


--
-- Name: TABLE task_logs; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.task_logs IS 'T3.2: Streaming execution logs for live UI';


--
-- Name: task_verification_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_verification_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    task_id uuid NOT NULL,
    scope text DEFAULT 'task'::text NOT NULL,
    result text DEFAULT 'pending'::text NOT NULL,
    criteria jsonb DEFAULT '[]'::jsonb NOT NULL,
    evidence jsonb DEFAULT '[]'::jsonb,
    target_host text,
    target_port integer,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    duration_ms bigint,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tasks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plan_id uuid NOT NULL,
    phase_index integer NOT NULL,
    name text NOT NULL,
    status public.task_status DEFAULT 'planned'::public.task_status,
    instruction text NOT NULL,
    acceptance_criteria jsonb DEFAULT '[]'::jsonb,
    depends_on uuid[] DEFAULT '{}'::uuid[],
    pre_checks jsonb DEFAULT '[]'::jsonb,
    post_review boolean DEFAULT true,
    retry_count integer DEFAULT 0,
    max_retries integer DEFAULT 3,
    timeout_minutes integer DEFAULT 30,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    completed_at timestamp with time zone,
    environment text DEFAULT 'dev'::text NOT NULL,
    verification_method text DEFAULT 'ssh'::text,
    verification_target jsonb DEFAULT '{}'::jsonb,
    cost_usd numeric(10,4) DEFAULT 0,
    duration_ms bigint DEFAULT 0,
    execution_summary text
);


--
-- Name: TABLE tasks; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.tasks IS 'T3.2: Individual work units within a plan phase';


--
-- Name: team_allowlist; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.team_allowlist (
    tailscale_login_name text NOT NULL,
    added_by uuid,
    added_at timestamp with time zone DEFAULT now() NOT NULL,
    notes text DEFAULT ''::text
);


--
-- Name: team_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.team_config (
    key text NOT NULL,
    value text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    email character varying(255),
    name character varying(255),
    created_at timestamp with time zone DEFAULT now(),
    tailscale_login_name text,
    display_name text DEFAULT ''::text NOT NULL,
    profile_pic_url text DEFAULT ''::text,
    role text DEFAULT 'member'::text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    first_seen timestamp with time zone DEFAULT now() NOT NULL,
    last_seen timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT users_role_check CHECK ((role = ANY (ARRAY['owner'::text, 'member'::text]))),
    CONSTRAINT users_status_check CHECK ((status = ANY (ARRAY['active'::text, 'disabled'::text])))
);


--
-- Name: verification_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.verification_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    controller_id uuid NOT NULL,
    project_id uuid NOT NULL,
    spec_id uuid,
    trigger text DEFAULT 'manual'::text NOT NULL,
    status text DEFAULT 'running'::text NOT NULL,
    commands_run jsonb DEFAULT '[]'::jsonb,
    failures jsonb DEFAULT '[]'::jsonb,
    error_count integer DEFAULT 0,
    warning_count integer DEFAULT 0,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    duration_ms integer,
    created_at timestamp with time zone DEFAULT now(),
    environment text DEFAULT 'dev'::text NOT NULL,
    CONSTRAINT chk_verification_runs_env CHECK ((environment = ANY (ARRAY['dev'::text, 'prod'::text, 'coder'::text, 'user'::text])))
);


--
-- Name: agents agents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_pkey PRIMARY KEY (id);


--
-- Name: app_settings app_settings_env_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_settings
    ADD CONSTRAINT app_settings_env_key UNIQUE (env);


--
-- Name: app_settings app_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_settings
    ADD CONSTRAINT app_settings_pkey PRIMARY KEY (id);


--
-- Name: credentials credentials_env_provider_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credentials
    ADD CONSTRAINT credentials_env_provider_name_key UNIQUE (env, provider, name);


--
-- Name: credentials credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credentials
    ADD CONSTRAINT credentials_pkey PRIMARY KEY (id);


--
-- Name: dlq_messages dlq_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dlq_messages
    ADD CONSTRAINT dlq_messages_pkey PRIMARY KEY (id);


--
-- Name: event_outbox event_outbox_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_outbox
    ADD CONSTRAINT event_outbox_pkey PRIMARY KEY (id);


--
-- Name: event_receipts event_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_receipts
    ADD CONSTRAINT event_receipts_pkey PRIMARY KEY (idempotency_key);


--
-- Name: execution_evidence execution_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.execution_evidence
    ADD CONSTRAINT execution_evidence_pkey PRIMARY KEY (id);


--
-- Name: generated_specs generated_specs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generated_specs
    ADD CONSTRAINT generated_specs_pkey PRIMARY KEY (id);


--
-- Name: integration_scans integration_scans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_scans
    ADD CONSTRAINT integration_scans_pkey PRIMARY KEY (id);


--
-- Name: machine_manifests machine_manifests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.machine_manifests
    ADD CONSTRAINT machine_manifests_pkey PRIMARY KEY (id);


--
-- Name: machines machines_nkey_public_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.machines
    ADD CONSTRAINT machines_nkey_public_key UNIQUE (nkey_public);


--
-- Name: machines machines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.machines
    ADD CONSTRAINT machines_pkey PRIMARY KEY (id);


--
-- Name: network_audit_log network_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.network_audit_log
    ADD CONSTRAINT network_audit_log_pkey PRIMARY KEY (id);


--
-- Name: network_join_tokens network_join_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.network_join_tokens
    ADD CONSTRAINT network_join_tokens_pkey PRIMARY KEY (id);


--
-- Name: network_join_tokens network_join_tokens_token_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.network_join_tokens
    ADD CONSTRAINT network_join_tokens_token_key UNIQUE (token);


--
-- Name: network_nodes network_nodes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.network_nodes
    ADD CONSTRAINT network_nodes_pkey PRIMARY KEY (id);


--
-- Name: networks networks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.networks
    ADD CONSTRAINT networks_pkey PRIMARY KEY (id);


--
-- Name: networks networks_project_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.networks
    ADD CONSTRAINT networks_project_id_key UNIQUE (project_id);


--
-- Name: plans plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plans
    ADD CONSTRAINT plans_pkey PRIMARY KEY (id);


--
-- Name: project_components project_components_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_components
    ADD CONSTRAINT project_components_pkey PRIMARY KEY (id);


--
-- Name: project_components project_components_project_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_components
    ADD CONSTRAINT project_components_project_id_name_key UNIQUE (project_id, name);


--
-- Name: project_connections project_connections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_connections
    ADD CONSTRAINT project_connections_pkey PRIMARY KEY (id);


--
-- Name: project_connections project_connections_project_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_connections
    ADD CONSTRAINT project_connections_project_id_key UNIQUE (project_id);


--
-- Name: project_deployments project_deployments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_deployments
    ADD CONSTRAINT project_deployments_pkey PRIMARY KEY (id);


--
-- Name: project_deployments project_deployments_project_id_machine_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_deployments
    ADD CONSTRAINT project_deployments_project_id_machine_id_key UNIQUE (project_id, machine_id);


--
-- Name: project_links project_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_links
    ADD CONSTRAINT project_links_pkey PRIMARY KEY (id);


--
-- Name: project_links project_links_source_project_id_target_project_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_links
    ADD CONSTRAINT project_links_source_project_id_target_project_id_key UNIQUE (source_project_id, target_project_id);


--
-- Name: projects projects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (id);


--
-- Name: protected_resources protected_resources_env_resource_type_resource_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.protected_resources
    ADD CONSTRAINT protected_resources_env_resource_type_resource_id_key UNIQUE (env, resource_type, resource_id);


--
-- Name: protected_resources protected_resources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.protected_resources
    ADD CONSTRAINT protected_resources_pkey PRIMARY KEY (id);


--
-- Name: rate_limits rate_limits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rate_limits
    ADD CONSTRAINT rate_limits_pkey PRIMARY KEY (key, env);


--
-- Name: recovery_attempts recovery_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_attempts
    ADD CONSTRAINT recovery_attempts_pkey PRIMARY KEY (id);


--
-- Name: sentry_issues sentry_issues_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentry_issues
    ADD CONSTRAINT sentry_issues_pkey PRIMARY KEY (id);


--
-- Name: sentry_issues sentry_issues_project_id_sentry_issue_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentry_issues
    ADD CONSTRAINT sentry_issues_project_id_sentry_issue_id_key UNIQUE (project_id, sentry_issue_id);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: task_artifacts task_artifacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_artifacts
    ADD CONSTRAINT task_artifacts_pkey PRIMARY KEY (id);


--
-- Name: task_attempts task_attempts_dispatch_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_attempts
    ADD CONSTRAINT task_attempts_dispatch_id_key UNIQUE (dispatch_id);


--
-- Name: task_attempts task_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_attempts
    ADD CONSTRAINT task_attempts_pkey PRIMARY KEY (id);


--
-- Name: task_attempts task_attempts_task_id_attempt_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_attempts
    ADD CONSTRAINT task_attempts_task_id_attempt_number_key UNIQUE (task_id, attempt_number);


--
-- Name: task_logs task_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_logs
    ADD CONSTRAINT task_logs_pkey PRIMARY KEY (id);


--
-- Name: task_verification_runs task_verification_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_verification_runs
    ADD CONSTRAINT task_verification_runs_pkey PRIMARY KEY (id);


--
-- Name: tasks tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_pkey PRIMARY KEY (id);


--
-- Name: team_allowlist team_allowlist_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_allowlist
    ADD CONSTRAINT team_allowlist_pkey PRIMARY KEY (tailscale_login_name);


--
-- Name: team_config team_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_config
    ADD CONSTRAINT team_config_pkey PRIMARY KEY (key);


--
-- Name: projects uq_projects_controller_path_env; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT uq_projects_controller_path_env UNIQUE (controller_id, path, environment);


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: verification_runs verification_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.verification_runs
    ADD CONSTRAINT verification_runs_pkey PRIMARY KEY (id);


--
-- Name: idx_artifacts_attempt; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_artifacts_attempt ON public.task_artifacts USING btree (attempt_id);


--
-- Name: idx_attempts_dispatch; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_attempts_dispatch ON public.task_attempts USING btree (dispatch_id);


--
-- Name: idx_attempts_env; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_attempts_env ON public.task_attempts USING btree (environment);


--
-- Name: idx_attempts_machine; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_attempts_machine ON public.task_attempts USING btree (machine_id);


--
-- Name: idx_attempts_task; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_attempts_task ON public.task_attempts USING btree (task_id, attempt_number);


--
-- Name: idx_credentials_env; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_credentials_env ON public.credentials USING btree (env);


--
-- Name: idx_credentials_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_credentials_provider ON public.credentials USING btree (provider);


--
-- Name: idx_dlq_env_status_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dlq_env_status_created ON public.dlq_messages USING btree (environment, status, created_at DESC);


--
-- Name: idx_event_outbox_env_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_outbox_env_status ON public.event_outbox USING btree (environment, status, created_at) WHERE (status = 'pending'::text);


--
-- Name: idx_event_outbox_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_outbox_pending ON public.event_outbox USING btree (status, created_at) WHERE (status = 'pending'::text);


--
-- Name: idx_event_outbox_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_outbox_type ON public.event_outbox USING btree (event_type);


--
-- Name: idx_event_receipts_env; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_receipts_env ON public.event_receipts USING btree (environment);


--
-- Name: idx_event_receipts_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_receipts_status ON public.event_receipts USING btree (status);


--
-- Name: idx_event_receipts_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_receipts_type ON public.event_receipts USING btree (event_type);


--
-- Name: idx_exec_evidence_task; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_exec_evidence_task ON public.execution_evidence USING btree (task_id);


--
-- Name: idx_generated_specs_env_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_generated_specs_env_project ON public.generated_specs USING btree (environment, project_id, created_at DESC);


--
-- Name: idx_generated_specs_environment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_generated_specs_environment ON public.generated_specs USING btree (environment);


--
-- Name: idx_generated_specs_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_generated_specs_project ON public.generated_specs USING btree (project_id, created_at DESC);


--
-- Name: idx_generated_specs_signature; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_generated_specs_signature ON public.generated_specs USING btree (project_id, failure_signature, created_at DESC);


--
-- Name: idx_generated_specs_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_generated_specs_status ON public.generated_specs USING btree (status);


--
-- Name: idx_generated_specs_trigger; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_generated_specs_trigger ON public.generated_specs USING btree (trigger_id);


--
-- Name: idx_int_scans_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_int_scans_created ON public.integration_scans USING btree (created_at DESC);


--
-- Name: idx_int_scans_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_int_scans_project ON public.integration_scans USING btree (project_id);


--
-- Name: idx_int_scans_scanner; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_int_scans_scanner ON public.integration_scans USING btree (scanner);


--
-- Name: idx_int_scans_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_int_scans_status ON public.integration_scans USING btree (status);


--
-- Name: idx_integration_scans_task; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_integration_scans_task ON public.integration_scans USING btree (triggered_by_task_id) WHERE (triggered_by_task_id IS NOT NULL);


--
-- Name: idx_logs_task; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_logs_task ON public.task_logs USING btree (task_id, "timestamp" DESC);


--
-- Name: idx_logs_task_attempt; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_logs_task_attempt ON public.task_logs USING btree (task_id, attempt_number);


--
-- Name: idx_machines_env; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_machines_env ON public.machines USING btree (environment);


--
-- Name: idx_machines_owner; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_machines_owner ON public.machines USING btree (owner_id);


--
-- Name: idx_machines_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_machines_status ON public.machines USING btree (status);


--
-- Name: idx_manifests_machine; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_manifests_machine ON public.machine_manifests USING btree (machine_id, project_id, pushed_at DESC);


--
-- Name: idx_network_audit_log_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_network_audit_log_created_at ON public.network_audit_log USING btree (created_at);


--
-- Name: idx_network_audit_log_network_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_network_audit_log_network_id ON public.network_audit_log USING btree (network_id);


--
-- Name: idx_network_join_tokens_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_network_join_tokens_expires_at ON public.network_join_tokens USING btree (expires_at);


--
-- Name: idx_network_join_tokens_network_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_network_join_tokens_network_id ON public.network_join_tokens USING btree (network_id);


--
-- Name: idx_network_nodes_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_network_nodes_agent_id ON public.network_nodes USING btree (agent_id);


--
-- Name: idx_network_nodes_claim_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_network_nodes_claim_token ON public.network_nodes USING btree (claim_token_hash) WHERE ((claim_token_hash IS NOT NULL) AND (claim_token_used = false));


--
-- Name: idx_network_nodes_machine_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_network_nodes_machine_id ON public.network_nodes USING btree (network_id, machine_id) WHERE (machine_id IS NOT NULL);


--
-- Name: idx_network_nodes_network_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_network_nodes_network_id ON public.network_nodes USING btree (network_id);


--
-- Name: idx_network_nodes_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_network_nodes_status ON public.network_nodes USING btree (status);


--
-- Name: idx_networks_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_networks_project_id ON public.networks USING btree (project_id);


--
-- Name: idx_plans_env; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_plans_env ON public.plans USING btree (environment);


--
-- Name: idx_plans_machine; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_plans_machine ON public.plans USING btree (machine_id);


--
-- Name: idx_plans_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_plans_project ON public.plans USING btree (project_id);


--
-- Name: idx_plans_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_plans_status ON public.plans USING btree (status);


--
-- Name: idx_project_components_project_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_project_components_project_id ON public.project_components USING btree (project_id);


--
-- Name: idx_project_connections_machine; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_project_connections_machine ON public.project_connections USING btree (machine_id);


--
-- Name: idx_project_connections_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_project_connections_type ON public.project_connections USING btree (connection_type);


--
-- Name: idx_project_deployments_machine; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_project_deployments_machine ON public.project_deployments USING btree (machine_id);


--
-- Name: idx_project_deployments_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_project_deployments_project ON public.project_deployments USING btree (project_id);


--
-- Name: idx_project_links_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_project_links_source ON public.project_links USING btree (source_project_id);


--
-- Name: idx_project_links_target; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_project_links_target ON public.project_links USING btree (target_project_id);


--
-- Name: idx_projects_controller_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_projects_controller_id ON public.projects USING btree (controller_id);


--
-- Name: idx_projects_env_controller; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_projects_env_controller ON public.projects USING btree (environment, controller_id);


--
-- Name: idx_projects_env_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_projects_env_slug ON public.projects USING btree (environment, slug) WHERE (slug IS NOT NULL);


--
-- Name: idx_projects_environment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_projects_environment ON public.projects USING btree (environment);


--
-- Name: idx_projects_health_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_projects_health_status ON public.projects USING btree (((health ->> 'status'::text)));


--
-- Name: idx_projects_path; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_projects_path ON public.projects USING btree (path);


--
-- Name: idx_protected_resources_env; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_protected_resources_env ON public.protected_resources USING btree (env);


--
-- Name: idx_protected_resources_resource; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_protected_resources_resource ON public.protected_resources USING btree (resource_type, resource_id);


--
-- Name: idx_rate_limits_env; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rate_limits_env ON public.rate_limits USING btree (env);


--
-- Name: idx_rate_limits_first_attempt; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rate_limits_first_attempt ON public.rate_limits USING btree (first_attempt);


--
-- Name: idx_recovery_attempts_env_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_attempts_env_project ON public.recovery_attempts USING btree (environment, project_id, created_at DESC);


--
-- Name: idx_recovery_attempts_environment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_attempts_environment ON public.recovery_attempts USING btree (environment);


--
-- Name: idx_recovery_attempts_escalated; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_attempts_escalated ON public.recovery_attempts USING btree (project_id, escalated) WHERE (escalated = true);


--
-- Name: idx_recovery_attempts_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_attempts_project ON public.recovery_attempts USING btree (project_id, created_at DESC);


--
-- Name: idx_recovery_attempts_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_attempts_status ON public.recovery_attempts USING btree (status);


--
-- Name: idx_recovery_attempts_verification; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recovery_attempts_verification ON public.recovery_attempts USING btree (verification_run_id);


--
-- Name: idx_sentry_last_seen; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sentry_last_seen ON public.sentry_issues USING btree (last_seen DESC);


--
-- Name: idx_sentry_level; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sentry_level ON public.sentry_issues USING btree (level);


--
-- Name: idx_sentry_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sentry_project ON public.sentry_issues USING btree (project_id);


--
-- Name: idx_sentry_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sentry_status ON public.sentry_issues USING btree (status);


--
-- Name: idx_sessions_access_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sessions_access_token ON public.sessions USING btree (access_token_hash) WHERE (revoked = false);


--
-- Name: idx_sessions_environment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sessions_environment ON public.sessions USING btree (environment);


--
-- Name: idx_sessions_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sessions_expires ON public.sessions USING btree (expires_at);


--
-- Name: idx_sessions_refresh_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sessions_refresh_token ON public.sessions USING btree (refresh_token_hash) WHERE (revoked = false);


--
-- Name: idx_sessions_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sessions_user_id ON public.sessions USING btree (user_id) WHERE (user_id IS NOT NULL);


--
-- Name: idx_task_verify_runs_task; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_verify_runs_task ON public.task_verification_runs USING btree (task_id);


--
-- Name: idx_tasks_env; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_env ON public.tasks USING btree (environment);


--
-- Name: idx_tasks_plan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_plan ON public.tasks USING btree (plan_id, phase_index, status);


--
-- Name: idx_tasks_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_status ON public.tasks USING btree (status);


--
-- Name: idx_unique_network_hostname; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_unique_network_hostname ON public.network_nodes USING btree (network_id, hostname);


--
-- Name: idx_unique_network_machine_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_unique_network_machine_id ON public.network_nodes USING btree (network_id, machine_id) WHERE (machine_id IS NOT NULL);


--
-- Name: idx_users_tailscale_login; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_users_tailscale_login ON public.users USING btree (tailscale_login_name) WHERE (tailscale_login_name IS NOT NULL);


--
-- Name: idx_verification_runs_controller; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_verification_runs_controller ON public.verification_runs USING btree (controller_id);


--
-- Name: idx_verification_runs_env_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_verification_runs_env_project ON public.verification_runs USING btree (environment, project_id, created_at DESC);


--
-- Name: idx_verification_runs_environment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_verification_runs_environment ON public.verification_runs USING btree (environment);


--
-- Name: idx_verification_runs_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_verification_runs_project ON public.verification_runs USING btree (project_id, created_at DESC);


--
-- Name: idx_verification_runs_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_verification_runs_status ON public.verification_runs USING btree (status);


--
-- Name: credentials prevent_credential_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_credential_delete BEFORE DELETE ON public.credentials FOR EACH ROW EXECUTE FUNCTION public.prevent_protected_delete('credential');


--
-- Name: projects prevent_project_delete_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_project_delete_trigger BEFORE DELETE ON public.projects FOR EACH ROW EXECUTE FUNCTION public.prevent_project_delete();


--
-- Name: app_settings prevent_setting_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prevent_setting_delete BEFORE DELETE ON public.app_settings FOR EACH ROW EXECUTE FUNCTION public.prevent_protected_delete('setting');


--
-- Name: project_components project_components_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER project_components_updated_at BEFORE UPDATE ON public.project_components FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- Name: projects projects_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER projects_updated_at BEFORE UPDATE ON public.projects FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- Name: credentials protect_coder_credentials; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_coder_credentials AFTER INSERT ON public.credentials FOR EACH ROW EXECUTE FUNCTION public.auto_protect_coder_resource('credential');


--
-- Name: projects protect_coder_projects; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_coder_projects AFTER INSERT ON public.projects FOR EACH ROW EXECUTE FUNCTION public.auto_protect_coder_project();


--
-- Name: app_settings protect_coder_settings; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_coder_settings AFTER INSERT ON public.app_settings FOR EACH ROW EXECUTE FUNCTION public.auto_protect_coder_resource('setting');


--
-- Name: generated_specs trg_generated_specs_env_consistency; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_generated_specs_env_consistency BEFORE INSERT OR UPDATE OF environment ON public.generated_specs FOR EACH ROW EXECUTE FUNCTION public.check_project_env_consistency();


--
-- Name: projects trg_projects_env_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_projects_env_immutable BEFORE UPDATE OF environment ON public.projects FOR EACH ROW EXECUTE FUNCTION public.prevent_project_env_change();


--
-- Name: recovery_attempts trg_recovery_attempts_env_consistency; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_recovery_attempts_env_consistency BEFORE INSERT OR UPDATE OF environment ON public.recovery_attempts FOR EACH ROW EXECUTE FUNCTION public.check_project_env_consistency();


--
-- Name: verification_runs trg_verification_runs_env_consistency; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_verification_runs_env_consistency BEFORE INSERT OR UPDATE OF environment ON public.verification_runs FOR EACH ROW EXECUTE FUNCTION public.check_project_env_consistency();


--
-- Name: agents update_agents_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_agents_updated_at BEFORE UPDATE ON public.agents FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: app_settings update_app_settings_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_app_settings_updated_at BEFORE UPDATE ON public.app_settings FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: credentials update_credentials_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_credentials_updated_at BEFORE UPDATE ON public.credentials FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: network_nodes update_network_nodes_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_network_nodes_updated_at BEFORE UPDATE ON public.network_nodes FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: networks update_networks_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_networks_updated_at BEFORE UPDATE ON public.networks FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: projects update_projects_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_projects_updated_at BEFORE UPDATE ON public.projects FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: rate_limits update_rate_limits_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_rate_limits_updated_at BEFORE UPDATE ON public.rate_limits FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: agents agents_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE SET NULL;


--
-- Name: generated_specs generated_specs_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generated_specs
    ADD CONSTRAINT generated_specs_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: integration_scans integration_scans_triggered_by_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_scans
    ADD CONSTRAINT integration_scans_triggered_by_task_id_fkey FOREIGN KEY (triggered_by_task_id) REFERENCES public.tasks(id) ON DELETE SET NULL;


--
-- Name: machine_manifests machine_manifests_machine_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.machine_manifests
    ADD CONSTRAINT machine_manifests_machine_id_fkey FOREIGN KEY (machine_id) REFERENCES public.machines(id) ON DELETE CASCADE;


--
-- Name: network_audit_log network_audit_log_network_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.network_audit_log
    ADD CONSTRAINT network_audit_log_network_id_fkey FOREIGN KEY (network_id) REFERENCES public.networks(id) ON DELETE SET NULL;


--
-- Name: network_audit_log network_audit_log_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.network_audit_log
    ADD CONSTRAINT network_audit_log_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE SET NULL;


--
-- Name: network_join_tokens network_join_tokens_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.network_join_tokens
    ADD CONSTRAINT network_join_tokens_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: network_join_tokens network_join_tokens_network_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.network_join_tokens
    ADD CONSTRAINT network_join_tokens_network_id_fkey FOREIGN KEY (network_id) REFERENCES public.networks(id) ON DELETE CASCADE;


--
-- Name: network_nodes network_nodes_agent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.network_nodes
    ADD CONSTRAINT network_nodes_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES public.agents(id) ON DELETE SET NULL;


--
-- Name: network_nodes network_nodes_network_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.network_nodes
    ADD CONSTRAINT network_nodes_network_id_fkey FOREIGN KEY (network_id) REFERENCES public.networks(id) ON DELETE CASCADE;


--
-- Name: networks networks_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.networks
    ADD CONSTRAINT networks_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: plans plans_machine_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plans
    ADD CONSTRAINT plans_machine_id_fkey FOREIGN KEY (machine_id) REFERENCES public.machines(id) ON DELETE SET NULL;


--
-- Name: project_components project_components_node_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_components
    ADD CONSTRAINT project_components_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.network_nodes(id);


--
-- Name: project_components project_components_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_components
    ADD CONSTRAINT project_components_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: project_deployments project_deployments_machine_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_deployments
    ADD CONSTRAINT project_deployments_machine_id_fkey FOREIGN KEY (machine_id) REFERENCES public.machines(id) ON DELETE CASCADE;


--
-- Name: project_links project_links_accepted_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_links
    ADD CONSTRAINT project_links_accepted_by_fkey FOREIGN KEY (accepted_by) REFERENCES public.users(id);


--
-- Name: project_links project_links_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_links
    ADD CONSTRAINT project_links_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: project_links project_links_source_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_links
    ADD CONSTRAINT project_links_source_project_id_fkey FOREIGN KEY (source_project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: project_links project_links_target_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.project_links
    ADD CONSTRAINT project_links_target_project_id_fkey FOREIGN KEY (target_project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: projects projects_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: recovery_attempts recovery_attempts_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_attempts
    ADD CONSTRAINT recovery_attempts_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: recovery_attempts recovery_attempts_verification_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_attempts
    ADD CONSTRAINT recovery_attempts_verification_run_id_fkey FOREIGN KEY (verification_run_id) REFERENCES public.verification_runs(id) ON DELETE CASCADE;


--
-- Name: sentry_issues sentry_issues_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentry_issues
    ADD CONSTRAINT sentry_issues_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: sessions sessions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: task_artifacts task_artifacts_attempt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_artifacts
    ADD CONSTRAINT task_artifacts_attempt_id_fkey FOREIGN KEY (attempt_id) REFERENCES public.task_attempts(id) ON DELETE CASCADE;


--
-- Name: task_attempts task_attempts_machine_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_attempts
    ADD CONSTRAINT task_attempts_machine_id_fkey FOREIGN KEY (machine_id) REFERENCES public.machines(id) ON DELETE SET NULL;


--
-- Name: task_attempts task_attempts_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_attempts
    ADD CONSTRAINT task_attempts_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.tasks(id) ON DELETE CASCADE;


--
-- Name: task_logs task_logs_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_logs
    ADD CONSTRAINT task_logs_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.tasks(id) ON DELETE CASCADE;


--
-- Name: tasks tasks_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES public.plans(id) ON DELETE CASCADE;


--
-- Name: team_allowlist team_allowlist_added_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_allowlist
    ADD CONSTRAINT team_allowlist_added_by_fkey FOREIGN KEY (added_by) REFERENCES public.users(id);


--
-- Name: verification_runs verification_runs_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.verification_runs
    ADD CONSTRAINT verification_runs_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: dlq_messages Service role full access on dlq_messages; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service role full access on dlq_messages" ON public.dlq_messages TO service_role USING (true) WITH CHECK (true);


--
-- Name: agents Service role has full access to agents; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service role has full access to agents" ON public.agents TO service_role USING (true) WITH CHECK (true);


--
-- Name: network_audit_log Service role has full access to network_audit_log; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service role has full access to network_audit_log" ON public.network_audit_log TO service_role USING (true) WITH CHECK (true);


--
-- Name: network_join_tokens Service role has full access to network_join_tokens; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service role has full access to network_join_tokens" ON public.network_join_tokens TO service_role USING (true) WITH CHECK (true);


--
-- Name: network_nodes Service role has full access to network_nodes; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service role has full access to network_nodes" ON public.network_nodes TO service_role USING (true) WITH CHECK (true);


--
-- Name: networks Service role has full access to networks; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service role has full access to networks" ON public.networks TO service_role USING (true) WITH CHECK (true);


--
-- Name: project_links Service role has full access to project_links; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service role has full access to project_links" ON public.project_links TO service_role USING (true) WITH CHECK (true);


--
-- Name: projects Service role has full access to projects; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Service role has full access to projects" ON public.projects TO service_role USING (true) WITH CHECK (true);


--
-- Name: agents; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.agents ENABLE ROW LEVEL SECURITY;

--
-- Name: app_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: app_settings app_settings_service_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_settings_service_access ON public.app_settings TO service_role USING (true) WITH CHECK (true);


--
-- Name: credentials; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.credentials ENABLE ROW LEVEL SECURITY;

--
-- Name: credentials credentials_service_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY credentials_service_access ON public.credentials TO service_role USING (true) WITH CHECK (true);


--
-- Name: dlq_messages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.dlq_messages ENABLE ROW LEVEL SECURITY;

--
-- Name: event_outbox; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.event_outbox ENABLE ROW LEVEL SECURITY;

--
-- Name: event_receipts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.event_receipts ENABLE ROW LEVEL SECURITY;

--
-- Name: generated_specs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.generated_specs ENABLE ROW LEVEL SECURITY;

--
-- Name: network_audit_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.network_audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: network_join_tokens; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.network_join_tokens ENABLE ROW LEVEL SECURITY;

--
-- Name: network_nodes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.network_nodes ENABLE ROW LEVEL SECURITY;

--
-- Name: networks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.networks ENABLE ROW LEVEL SECURITY;

--
-- Name: project_components; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.project_components ENABLE ROW LEVEL SECURITY;

--
-- Name: project_deployments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.project_deployments ENABLE ROW LEVEL SECURITY;

--
-- Name: project_deployments project_deployments_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY project_deployments_delete ON public.project_deployments FOR DELETE USING (true);


--
-- Name: project_deployments project_deployments_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY project_deployments_insert ON public.project_deployments FOR INSERT WITH CHECK (true);


--
-- Name: project_deployments project_deployments_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY project_deployments_select ON public.project_deployments FOR SELECT USING (true);


--
-- Name: project_deployments project_deployments_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY project_deployments_update ON public.project_deployments FOR UPDATE USING (true);


--
-- Name: project_links; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.project_links ENABLE ROW LEVEL SECURITY;

--
-- Name: projects; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;

--
-- Name: protected_resources; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.protected_resources ENABLE ROW LEVEL SECURITY;

--
-- Name: protected_resources protected_resources_service_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY protected_resources_service_access ON public.protected_resources TO service_role USING (true) WITH CHECK (true);


--
-- Name: rate_limits; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.rate_limits ENABLE ROW LEVEL SECURITY;

--
-- Name: rate_limits rate_limits_service_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rate_limits_service_access ON public.rate_limits TO service_role USING (true) WITH CHECK (true);


--
-- Name: recovery_attempts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recovery_attempts ENABLE ROW LEVEL SECURITY;

--
-- Name: event_outbox service_role_full; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY service_role_full ON public.event_outbox TO service_role USING (true) WITH CHECK (true);


--
-- Name: event_receipts service_role_full; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY service_role_full ON public.event_receipts TO service_role USING (true) WITH CHECK (true);


--
-- Name: generated_specs service_role_full; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY service_role_full ON public.generated_specs TO service_role USING (true) WITH CHECK (true);


--
-- Name: project_components service_role_full; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY service_role_full ON public.project_components TO service_role USING (true) WITH CHECK (true);


--
-- Name: recovery_attempts service_role_full; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY service_role_full ON public.recovery_attempts TO service_role USING (true) WITH CHECK (true);


--
-- Name: sessions service_role_full; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY service_role_full ON public.sessions TO service_role USING (true) WITH CHECK (true);


--
-- Name: users service_role_full; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY service_role_full ON public.users TO service_role USING (true) WITH CHECK (true);


--
-- Name: verification_runs service_role_full; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY service_role_full ON public.verification_runs TO service_role USING (true) WITH CHECK (true);


--
-- Name: sessions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

--
-- Name: verification_runs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.verification_runs ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--


-- ============================================================
-- Grants for PostgREST
-- ============================================================
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role, authenticator;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role, authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO service_role, authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role, authenticated;
