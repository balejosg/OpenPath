ALTER TABLE "machine_exemptions" DROP CONSTRAINT "machine_exemptions_machine_schedule_expires_key";--> statement-breakpoint
ALTER TABLE "machine_exemptions" ALTER COLUMN "schedule_id" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "classrooms" ADD COLUMN "captive_portal_domains" text[] DEFAULT '{}'::text[] NOT NULL;--> statement-breakpoint
ALTER TABLE "health_reports" ADD COLUMN "firewall_active" integer;--> statement-breakpoint
ALTER TABLE "health_reports" ADD COLUMN "whitelist_age_hours" integer;--> statement-breakpoint
ALTER TABLE "health_reports" ADD COLUMN "captive_portal_mode" integer;--> statement-breakpoint
ALTER TABLE "machine_exemptions" ADD COLUMN "source" varchar(20) DEFAULT 'schedule' NOT NULL;--> statement-breakpoint
ALTER TABLE "machine_exemptions" ADD COLUMN "reason" text;--> statement-breakpoint
ALTER TABLE "whitelist_rules" ADD COLUMN "enabled" integer DEFAULT 1 NOT NULL;--> statement-breakpoint
CREATE UNIQUE INDEX "machine_exemptions_machine_schedule_expires_key" ON "machine_exemptions" USING btree ("machine_id","schedule_id","expires_at") WHERE "machine_exemptions"."source" = 'schedule';--> statement-breakpoint
CREATE UNIQUE INDEX "machine_exemptions_machine_operational_expires_key" ON "machine_exemptions" USING btree ("machine_id","expires_at") WHERE "machine_exemptions"."source" = 'operational' AND "machine_exemptions"."schedule_id" IS NULL;--> statement-breakpoint
ALTER TABLE "machine_exemptions" ADD CONSTRAINT "machine_exemptions_source_schedule_id_check" CHECK ("machine_exemptions"."source" IN ('schedule', 'operational') AND (("machine_exemptions"."source" = 'schedule' AND "machine_exemptions"."schedule_id" IS NOT NULL) OR ("machine_exemptions"."source" = 'operational' AND "machine_exemptions"."schedule_id" IS NULL)));