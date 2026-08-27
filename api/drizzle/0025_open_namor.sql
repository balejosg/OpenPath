ALTER TABLE "windows_offline_download_refs" ADD COLUMN "artifact_storage_file_name" varchar(255);
--> statement-breakpoint
UPDATE "windows_offline_download_refs"
SET "artifact_storage_file_name" = left("reference_hash", 32) || '.exe'
WHERE "artifact_storage_file_name" IS NULL;
--> statement-breakpoint
ALTER TABLE "windows_offline_download_refs"
ALTER COLUMN "artifact_storage_file_name" SET NOT NULL;
