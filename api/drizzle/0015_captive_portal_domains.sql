ALTER TABLE "classrooms" ADD COLUMN IF NOT EXISTS "captive_portal_domains" text[] DEFAULT '{}'::text[] NOT NULL;
