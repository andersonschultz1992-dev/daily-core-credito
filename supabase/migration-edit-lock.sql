-- DAILY CORE & CRÉDITO — Migração v8.2: bloqueio cooperativo de edição
-- Execute uma vez no SQL Editor do Supabase antes de publicar a versão v8.2.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS public.app_edit_locks (
  lock_key     TEXT        PRIMARY KEY,
  owner_token  UUID        NOT NULL,
  expires_at   TIMESTAMPTZ NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_app_edit_locks_expires
  ON public.app_edit_locks(expires_at);

CREATE OR REPLACE FUNCTION public.acquire_app_edit_lock(
  p_lock_key TEXT,
  p_owner_token UUID,
  p_ttl_seconds INTEGER DEFAULT 120
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows INTEGER;
  v_ttl INTEGER := LEAST(GREATEST(COALESCE(p_ttl_seconds, 120), 30), 600);
BEGIN
  INSERT INTO public.app_edit_locks AS current_lock (lock_key, owner_token, expires_at, created_at, updated_at)
  VALUES (p_lock_key, p_owner_token, now() + make_interval(secs => v_ttl), now(), now())
  ON CONFLICT (lock_key) DO UPDATE
    SET owner_token = EXCLUDED.owner_token,
        expires_at  = EXCLUDED.expires_at,
        updated_at  = now()
    WHERE current_lock.owner_token = EXCLUDED.owner_token
       OR current_lock.expires_at <= now();
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows > 0;
END;
$$;

CREATE OR REPLACE FUNCTION public.renew_app_edit_lock(
  p_lock_key TEXT,
  p_owner_token UUID,
  p_ttl_seconds INTEGER DEFAULT 120
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows INTEGER;
  v_ttl INTEGER := LEAST(GREATEST(COALESCE(p_ttl_seconds, 120), 30), 600);
BEGIN
  UPDATE public.app_edit_locks
     SET expires_at = now() + make_interval(secs => v_ttl),
         updated_at = now()
   WHERE lock_key = p_lock_key
     AND owner_token = p_owner_token
     AND expires_at > now();
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows > 0;
END;
$$;

CREATE OR REPLACE FUNCTION public.release_app_edit_lock(
  p_lock_key TEXT,
  p_owner_token UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows INTEGER;
BEGIN
  DELETE FROM public.app_edit_locks
   WHERE lock_key = p_lock_key
     AND owner_token = p_owner_token;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows > 0;
END;
$$;

ALTER TABLE public.app_edit_locks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.app_edit_locks FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.acquire_app_edit_lock(TEXT, UUID, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.renew_app_edit_lock(TEXT, UUID, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.release_app_edit_lock(TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.acquire_app_edit_lock(TEXT, UUID, INTEGER) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.renew_app_edit_lock(TEXT, UUID, INTEGER) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.release_app_edit_lock(TEXT, UUID) TO anon, authenticated;
