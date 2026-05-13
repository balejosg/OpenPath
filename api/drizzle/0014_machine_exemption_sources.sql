ALTER TABLE "machine_exemptions" ALTER COLUMN "schedule_id" DROP NOT NULL;
--> statement-breakpoint
ALTER TABLE "machine_exemptions" ADD COLUMN IF NOT EXISTS "source" varchar(20) DEFAULT 'schedule' NOT NULL;
--> statement-breakpoint
ALTER TABLE "machine_exemptions" ADD COLUMN IF NOT EXISTS "reason" text;
--> statement-breakpoint
ALTER TABLE "machine_exemptions" DROP CONSTRAINT IF EXISTS "machine_exemptions_machine_schedule_expires_key";
--> statement-breakpoint
DROP INDEX IF EXISTS "machine_exemptions_machine_schedule_expires_key";
--> statement-breakpoint
DROP INDEX IF EXISTS "machine_exemptions_machine_operational_expires_key";
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "machine_exemptions_machine_schedule_expires_key" ON "machine_exemptions" ("machine_id","schedule_id","expires_at") WHERE "source" = 'schedule';
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "machine_exemptions_machine_operational_expires_key" ON "machine_exemptions" ("machine_id","expires_at") WHERE "source" = 'operational' AND "schedule_id" IS NULL;
--> statement-breakpoint
DO $$ BEGIN
  ALTER TABLE "machine_exemptions" ADD CONSTRAINT "machine_exemptions_source_schedule_id_check" CHECK ("source" IN ('schedule', 'operational') AND (("source" = 'schedule' AND "schedule_id" IS NOT NULL) OR ("source" = 'operational' AND "schedule_id" IS NULL)));
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
