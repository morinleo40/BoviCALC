-- ═══════════════════════════════════════════════════════════
-- Migration RumiCORE Conseiller v2 — nouvelles fonctionnalités
-- À exécuter dans Supabase → SQL Editor (une seule fois)
-- ═══════════════════════════════════════════════════════════

-- 1) Objectifs de suivi par exploitation
ALTER TABLE exploitations ADD COLUMN IF NOT EXISTS objectifs jsonb;

-- 2) Carnet de visite multimédia + indicateurs terrain
ALTER TABLE visit_notes ADD COLUMN IF NOT EXISTS photo_url text;
ALTER TABLE visit_notes ADD COLUMN IF NOT EXISTS audio_url text;
ALTER TABLE visit_notes ADD COLUMN IF NOT EXISTS refus text;      -- 'baisse' | 'stable' | 'hausse'
ALTER TABLE visit_notes ADD COLUMN IF NOT EXISTS ingestion text;  -- 'baisse' | 'stable' | 'hausse'

-- 3) Base aliments + prix centralisés du conseiller
CREATE TABLE IF NOT EXISTS conseiller_aliments (
  id uuid primary key default gen_random_uuid(),
  advisor_id uuid not null references auth.users(id) on delete cascade,
  nom text not null,
  prix numeric,       -- €/t
  ufl numeric,
  pdi numeric,
  ms numeric,
  fournisseur text,
  updated_at timestamptz default now()
);
ALTER TABLE conseiller_aliments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "ca_all_own" ON conseiller_aliments;
CREATE POLICY "ca_all_own" ON conseiller_aliments FOR ALL TO authenticated
  USING (advisor_id = auth.uid()) WITH CHECK (advisor_id = auth.uid());

-- 4) Stockage photos/audio des visites
-- ⚠️ Étape manuelle requise : Dashboard Supabase → Storage → New bucket
--    Nom : visite-media   |   Public : NON (privé)
-- Puis exécuter les policies ci-dessous (une fois le bucket créé) :
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'visite-media') THEN
    DROP POLICY IF EXISTS "visite_media_rw" ON storage.objects;
    CREATE POLICY "visite_media_rw" ON storage.objects FOR ALL TO authenticated
      USING (bucket_id = 'visite-media' AND owner = auth.uid())
      WITH CHECK (bucket_id = 'visite-media' AND owner = auth.uid());
  END IF;
END $$;

-- 5) Analyses de fourrage (saisie assistée + photo du bulletin labo)
CREATE TABLE IF NOT EXISTS analyses_fourrage (
  id uuid primary key default gen_random_uuid(),
  exploitation_id uuid not null references exploitations(id) on delete cascade,
  advisor_id uuid not null references auth.users(id) on delete cascade,
  nom text not null,
  type text,          -- ex: ensilage maïs, foin, enrubannage...
  laboratoire text,
  date_analyse date,
  ms numeric, mat numeric, cb numeric, ndf numeric, amidon numeric,
  mat_dig numeric, ufl numeric, pdi numeric,
  photo_url text,
  created_at timestamptz default now()
);
ALTER TABLE analyses_fourrage ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "af_all_own" ON analyses_fourrage;
CREATE POLICY "af_all_own" ON analyses_fourrage FOR ALL TO authenticated
  USING (advisor_id = auth.uid()) WITH CHECK (advisor_id = auth.uid());

-- 6) Benchmark inter-organismes (anonymisé, réel — pas de fausses données)
-- Agrège les dernières sessions de TOUS les conseillers pour un type d'exploitation donné,
-- mais ne renvoie que des médianes (jamais de ligne individuelle), et seulement si au moins
-- 3 organismes/conseillers distincts contribuent — sinon nb_organismes < 3 côté client = masqué.
DROP FUNCTION IF EXISTS public.get_cross_benchmark(text, uuid);
CREATE OR REPLACE FUNCTION public.get_cross_benchmark(p_type text, p_exclude_exp uuid DEFAULT NULL)
RETURNS TABLE(med_lait numeric, med_tb numeric, med_cout numeric, nb_exploitations int, nb_organismes int)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN QUERY
  WITH exps AS (
    SELECT id, conseiller_id FROM exploitations
    WHERE type = p_type AND (p_exclude_exp IS NULL OR id <> p_exclude_exp)
  ),
  latest AS (
    SELECT DISTINCT ON (s.exploitation_id) s.exploitation_id, e.conseiller_id, s.data
    FROM exploitation_sessions s
    JOIN exps e ON e.id = s.exploitation_id
    ORDER BY s.exploitation_id, s.date DESC
  ),
  agg AS (
    SELECT
      (l.data->'animalParams'->>'prod')::numeric AS lait,
      (l.data->'animalParams'->>'tb')::numeric AS tb,
      (l.data->>'coutJour')::numeric AS cout,
      l.conseiller_id
    FROM latest l
  )
  SELECT
    (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY lait) FROM agg WHERE lait IS NOT NULL),
    (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY tb) FROM agg WHERE tb IS NOT NULL),
    (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY cout) FROM agg WHERE cout IS NOT NULL),
    (SELECT count(*)::int FROM agg),
    (SELECT count(DISTINCT conseiller_id)::int FROM agg);
END; $$;
GRANT EXECUTE ON FUNCTION public.get_cross_benchmark(text, uuid) TO authenticated;

-- 7) Profil "organisme" du conseiller (co-branding — logo/couleur, ex: NatUp)
CREATE TABLE IF NOT EXISTS advisor_profiles (
  advisor_id uuid primary key references auth.users(id) on delete cascade,
  organisation text,
  logo_url text,
  couleur_primaire text,
  updated_at timestamptz default now()
);
ALTER TABLE advisor_profiles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "ap_all_own" ON advisor_profiles;
CREATE POLICY "ap_all_own" ON advisor_profiles FOR ALL TO authenticated
  USING (advisor_id = auth.uid()) WITH CHECK (advisor_id = auth.uid());

-- 8) Stratégie alimentaire annuelle (calendrier de phases par exploitation)
ALTER TABLE exploitations ADD COLUMN IF NOT EXISTS strategie jsonb;

-- ═══════════════════════════════════════════════════════════
-- 9) INTERFACE ADMIN (admin.html)
-- Toutes les fonctions ci-dessous sont réservées aux emails admin
-- (bovicalc@gmail.com, morinleo40@gmail.com) — vérification interne à chaque appel.
-- ═══════════════════════════════════════════════════════════

-- 9.1) Liste complète des comptes avec plan, organisation, activité
DROP FUNCTION IF EXISTS public.get_admin_users();
CREATE OR REPLACE FUNCTION public.get_admin_users()
RETURNS TABLE(
  id uuid, email text, created_at timestamptz, last_sign_in_at timestamptz,
  banned_until timestamptz, plan text, plan_until timestamptz,
  organisation text, nb_exploitations int, nb_sessions int
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users au WHERE au.id = auth.uid() AND lower(au.email) IN ('bovicalc@gmail.com','morinleo40@gmail.com')) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  RETURN QUERY
  SELECT
    u.id, u.email::text, u.created_at, u.last_sign_in_at, u.banned_until,
    COALESCE(up.plan, u.raw_user_meta_data->>'plan') AS plan,
    NULLIF(u.raw_user_meta_data->>'plan_until','')::timestamptz,
    ap.organisation,
    (SELECT count(*)::int FROM exploitations e WHERE e.conseiller_id = u.id),
    (SELECT count(*)::int FROM exploitation_sessions s JOIN exploitations e ON e.id = s.exploitation_id WHERE e.conseiller_id = u.id)
  FROM auth.users u
  LEFT JOIN user_plans up ON up.user_id = u.id
  LEFT JOIN advisor_profiles ap ON ap.advisor_id = u.id
  ORDER BY u.created_at DESC;
END; $$;
GRANT EXECUTE ON FUNCTION public.get_admin_users() TO authenticated;

-- 9.2) Basculer un compte pro/gratuit directement (sans code promo)
DROP FUNCTION IF EXISTS public.admin_set_plan(uuid, text, timestamptz);
CREATE OR REPLACE FUNCTION public.admin_set_plan(p_user_id uuid, p_plan text, p_until timestamptz DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users au WHERE au.id = auth.uid() AND lower(au.email) IN ('bovicalc@gmail.com','morinleo40@gmail.com')) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;
  UPDATE auth.users
  SET raw_user_meta_data =
    (COALESCE(raw_user_meta_data,'{}'::jsonb) || jsonb_build_object('plan', p_plan))
    || CASE WHEN p_until IS NOT NULL THEN jsonb_build_object('plan_until', to_jsonb(p_until))
            ELSE jsonb_build_object('plan_until', NULL) END
  WHERE id = p_user_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_set_plan(uuid, text, timestamptz) TO authenticated;

-- 9.3) Assigner une organisation (ex: NatUp) à un compte — alimente aussi le co-branding
DROP FUNCTION IF EXISTS public.admin_set_organisation(uuid, text);
CREATE OR REPLACE FUNCTION public.admin_set_organisation(p_user_id uuid, p_organisation text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users au WHERE au.id = auth.uid() AND lower(au.email) IN ('bovicalc@gmail.com','morinleo40@gmail.com')) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;
  INSERT INTO advisor_profiles (advisor_id, organisation, updated_at)
  VALUES (p_user_id, NULLIF(p_organisation,''), now())
  ON CONFLICT (advisor_id) DO UPDATE SET organisation = excluded.organisation, updated_at = now();
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_set_organisation(uuid, text) TO authenticated;

-- 9.4) Suspendre / réactiver un compte (nécessite la colonne auth.users.banned_until,
-- présente sur les projets Supabase récents ; sinon la fonction échoue avec un message clair)
DROP FUNCTION IF EXISTS public.admin_set_banned(uuid, boolean);
CREATE OR REPLACE FUNCTION public.admin_set_banned(p_user_id uuid, p_banned boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users au WHERE au.id = auth.uid() AND lower(au.email) IN ('bovicalc@gmail.com','morinleo40@gmail.com')) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;
  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Impossible de suspendre votre propre compte admin';
  END IF;
  UPDATE auth.users
  SET banned_until = CASE WHEN p_banned THEN '3000-01-01T00:00:00Z'::timestamptz ELSE NULL END
  WHERE id = p_user_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_set_banned(uuid, boolean) TO authenticated;

-- 9.5) Supprimer définitivement un compte
DROP FUNCTION IF EXISTS public.admin_delete_user(uuid);
CREATE OR REPLACE FUNCTION public.admin_delete_user(p_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users au WHERE au.id = auth.uid() AND lower(au.email) IN ('bovicalc@gmail.com','morinleo40@gmail.com')) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;
  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Impossible de supprimer votre propre compte admin';
  END IF;
  DELETE FROM auth.users WHERE id = p_user_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_delete_user(uuid) TO authenticated;
