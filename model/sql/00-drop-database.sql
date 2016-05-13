-- Terminate all database connections
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'dorscluc_db';

-- Drop database
DROP DATABASE "dorscluc_db";

-- Drop owner
DROP ROLE "dorscluc_user";
