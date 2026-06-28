DELETE FROM "whitelist_rules" WHERE "source" = 'auto_extension';
--> statement-breakpoint
ALTER TABLE "whitelist_rules" DROP COLUMN "source";
