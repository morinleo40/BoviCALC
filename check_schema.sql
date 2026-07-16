-- Liste les colonnes existantes sur edu_submissions et edu_exercises
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_name IN ('edu_submissions', 'edu_exercises')
ORDER BY table_name, ordinal_position;
