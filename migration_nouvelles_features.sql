-- ═══════════════════════════════════════════════════════════
-- Migration pour les nouvelles fonctionnalités RumiCORE
-- À exécuter dans Supabase → SQL Editor
-- ═══════════════════════════════════════════════════════════

-- 1) Quiz QCM (app_education.html)
ALTER TABLE edu_exercises ADD COLUMN IF NOT EXISTS type text DEFAULT 'ration';
ALTER TABLE edu_exercises ADD COLUMN IF NOT EXISTS qcm_questions jsonb;
ALTER TABLE edu_submissions ADD COLUMN IF NOT EXISTS qcm_pct numeric;
ALTER TABLE edu_submissions ADD COLUMN IF NOT EXISTS qcm_answers jsonb;

-- 2) Lien éleveur ↔ conseiller (partage de ration par code)
CREATE TABLE IF NOT EXISTS ration_shares (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  eleveur_id uuid,
  eleveur_email text,
  eleveur_name text,
  ration_data jsonb not null,
  created_at timestamptz default now(),
  claimed_by uuid,
  claimed_at timestamptz
);
ALTER TABLE ration_shares ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ration_shares_select" ON ration_shares;
CREATE POLICY "ration_shares_select" ON ration_shares FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "ration_shares_insert" ON ration_shares;
CREATE POLICY "ration_shares_insert" ON ration_shares FOR INSERT TO authenticated WITH CHECK (auth.uid() = eleveur_id);

DROP POLICY IF EXISTS "ration_shares_update" ON ration_shares;
CREATE POLICY "ration_shares_update" ON ration_shares FOR UPDATE TO authenticated USING (claimed_by IS NULL);
