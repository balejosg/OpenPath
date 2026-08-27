CREATE TABLE "windows_offline_download_transfer_leases" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"download_ref_id" uuid NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "windows_offline_download_transfer_leases" ADD CONSTRAINT "windows_offline_download_transfer_leases_download_ref_id_windows_offline_download_refs_id_fk" FOREIGN KEY ("download_ref_id") REFERENCES "public"."windows_offline_download_refs"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "windows_offline_transfer_leases_ref_idx" ON "windows_offline_download_transfer_leases" USING btree ("download_ref_id");--> statement-breakpoint
CREATE INDEX "windows_offline_transfer_leases_expires_idx" ON "windows_offline_download_transfer_leases" USING btree ("expires_at");
--> statement-breakpoint
-- active_transfers belonged to the pre-lease implementation. Migrations run
-- before the API accepts traffic, so stale counters can be safely recovered.
UPDATE "windows_offline_download_refs" SET "active_transfers" = 0 WHERE "active_transfers" > 0;
