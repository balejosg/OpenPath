ALTER TABLE "machine_exemptions" ADD COLUMN IF NOT EXISTS "group_id" varchar(50);--> statement-breakpoint
DO $$ BEGIN
  ALTER TABLE "machine_exemptions" ADD CONSTRAINT "machine_exemptions_group_id_whitelist_groups_id_fk" FOREIGN KEY ("group_id") REFERENCES "whitelist_groups"("id") ON DELETE set null ON UPDATE no action;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
