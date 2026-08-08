-- ═══════════════════════════════════════════════════════════
-- Fonction : liste détaillée des comptes Pro (email, origine, expiration)
-- Utilisée par le panneau admin de app.html ("Comptes Pro actifs")
-- À exécuter dans Supabase → SQL Editor
-- ═══════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.get_pro_users();

CREATE OR REPLACE FUNCTION public.get_pro_users()
RETURNS TABLE(
  email text,
  source text,        -- 'promo' | 'paiement' | 'manuel'
  plan_until timestamptz,
  promo_code text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Réservé aux comptes admin (mêmes emails que côté client dans app.html)
  IF NOT EXISTS (
    SELECT 1 FROM auth.users au
    WHERE au.id = auth.uid()
      AND lower(au.email) IN ('bovicalc@gmail.com', 'morinleo40@gmail.com')
  ) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  RETURN QUERY
  SELECT
    u.email::text,
    CASE
      WHEN pc.code IS NOT NULL THEN 'promo'
      WHEN up.plan = 'pro'     THEN 'paiement'
      ELSE 'manuel'
    END,
    NULLIF(u.raw_user_meta_data->>'plan_until', '')::timestamptz,
    pc.code,
    u.created_at
  FROM auth.users u
  LEFT JOIN promo_codes pc ON pc.used_by = u.id AND pc.used = true
  LEFT JOIN user_plans up  ON up.user_id = u.id AND up.plan = 'pro'
  WHERE u.raw_user_meta_data->>'plan' = 'pro'
     OR up.plan = 'pro'
  ORDER BY u.created_at DESC;
END; $$;

GRANT EXECUTE ON FUNCTION public.get_pro_users() TO authenticated;
