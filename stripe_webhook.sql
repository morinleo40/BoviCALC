-- ═══════════════════════════════════════════════════════════
-- Intégration Stripe → Supabase (activation automatique du plan Pro)
-- À exécuter dans Supabase → SQL Editor (une seule fois)
-- ═══════════════════════════════════════════════════════════

-- Table utilisée par loadUserPlan() dans app.html comme fallback (déjà référencée
-- dans le code existant) — on s'assure ici qu'elle a la bonne forme, sans écraser
-- de données si elle existe déjà.
CREATE TABLE IF NOT EXISTS user_plans (
  user_id uuid primary key references auth.users(id) on delete cascade,
  plan text not null default 'free',
  updated_at timestamptz default now()
);
ALTER TABLE user_plans ADD COLUMN IF NOT EXISTS stripe_customer_id text;
ALTER TABLE user_plans ADD COLUMN IF NOT EXISTS stripe_subscription_id text;
ALTER TABLE user_plans ADD COLUMN IF NOT EXISTS current_period_end timestamptz;

CREATE UNIQUE INDEX IF NOT EXISTS user_plans_stripe_customer_idx ON user_plans(stripe_customer_id);

ALTER TABLE user_plans ENABLE ROW LEVEL SECURITY;

-- Chaque utilisateur peut lire SON plan (déjà utilisé par loadUserPlan())
DROP POLICY IF EXISTS "user_plans_select_own" ON user_plans;
CREATE POLICY "user_plans_select_own" ON user_plans FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- Aucune policy d'écriture pour les utilisateurs : seule l'Edge Function stripe-webhook
-- (via la clé service_role, qui contourne RLS) peut écrire dans cette table.
