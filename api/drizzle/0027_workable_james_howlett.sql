ALTER TABLE "classrooms" ADD COLUMN IF NOT EXISTS "active_unrestricted" boolean DEFAULT false NOT NULL;--> statement-breakpoint
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'classrooms_active_unrestricted_check'
  ) THEN
    ALTER TABLE "classrooms" ADD CONSTRAINT "classrooms_active_unrestricted_check" CHECK (NOT "classrooms"."active_unrestricted" OR "classrooms"."active_group_id" IS NULL);
  END IF;
END $$;
