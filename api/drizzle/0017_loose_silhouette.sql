ALTER TABLE "machine_exemptions" DROP CONSTRAINT IF EXISTS "machine_exemptions_machine_schedule_expires_key";--> statement-breakpoint
ALTER TABLE "machine_exemptions" ALTER COLUMN "schedule_id" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "classrooms" ADD COLUMN IF NOT EXISTS "captive_portal_domains" text[] DEFAULT '{}'::text[] NOT NULL;--> statement-breakpoint
ALTER TABLE "health_reports" ADD COLUMN IF NOT EXISTS "firewall_active" integer;--> statement-breakpoint
ALTER TABLE "health_reports" ADD COLUMN IF NOT EXISTS "whitelist_age_hours" integer;--> statement-breakpoint
ALTER TABLE "health_reports" ADD COLUMN IF NOT EXISTS "captive_portal_mode" integer;--> statement-breakpoint
ALTER TABLE "machine_exemptions" ADD COLUMN IF NOT EXISTS "source" varchar(20) DEFAULT 'schedule' NOT NULL;--> statement-breakpoint
ALTER TABLE "machine_exemptions" ADD COLUMN IF NOT EXISTS "reason" text;--> statement-breakpoint
ALTER TABLE "whitelist_rules" ADD COLUMN IF NOT EXISTS "enabled" integer DEFAULT 1 NOT NULL;--> statement-breakpoint
DROP INDEX IF EXISTS "machine_exemptions_machine_schedule_expires_key";--> statement-breakpoint
DROP INDEX IF EXISTS "machine_exemptions_machine_operational_expires_key";--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "machine_exemptions_machine_schedule_expires_key" ON "machine_exemptions" USING btree ("machine_id","schedule_id","expires_at") WHERE "machine_exemptions"."source" = 'schedule';--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "machine_exemptions_machine_operational_expires_key" ON "machine_exemptions" USING btree ("machine_id","expires_at") WHERE "machine_exemptions"."source" = 'operational' AND "machine_exemptions"."schedule_id" IS NULL;--> statement-breakpoint
DO $$ BEGIN
  ALTER TABLE "machine_exemptions" ADD CONSTRAINT "machine_exemptions_source_schedule_id_check" CHECK ("machine_exemptions"."source" IN ('schedule', 'operational') AND (("machine_exemptions"."source" = 'schedule' AND "machine_exemptions"."schedule_id" IS NOT NULL) OR ("machine_exemptions"."source" = 'operational' AND "machine_exemptions"."schedule_id" IS NULL)));
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
