ALTER TABLE edu_submissions ADD COLUMN IF NOT EXISTS exo_delta_pdi numeric;
ALTER TABLE edu_submissions ADD COLUMN IF NOT EXISTS qcm_pct numeric;
ALTER TABLE edu_submissions ADD COLUMN IF NOT EXISTS qcm_answers jsonb;
