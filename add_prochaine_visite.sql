-- ═══════════════════════════════════════════════════════════
-- Ajoute la date de prochaine visite programmée sur une exploitation
-- Utilisé par la "Fiche exploitation intelligente" de app_conseiller.html
-- À exécuter dans Supabase → SQL Editor
-- ═══════════════════════════════════════════════════════════

ALTER TABLE exploitations ADD COLUMN IF NOT EXISTS prochaine_visite date;
