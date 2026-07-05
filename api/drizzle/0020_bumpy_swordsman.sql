ALTER TABLE "health_reports" ADD COLUMN IF NOT EXISTS "health_report_fail_streak" integer;--> statement-breakpoint
ALTER TABLE "machines" ADD COLUMN IF NOT EXISTS "config_posture" jsonb;