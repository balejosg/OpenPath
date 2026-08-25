CREATE TABLE "windows_offline_download_refs" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"classroom_id" varchar(50) NOT NULL,
	"classroom_name" varchar(255) NOT NULL,
	"created_by" varchar(50),
	"reference_hash" varchar(64) NOT NULL,
	"artifact_file_name" varchar(255) NOT NULL,
	"artifact_sha256" varchar(64) NOT NULL,
	"artifact_size" bigint NOT NULL,
	"max_attempts" integer NOT NULL,
	"used_attempts" integer DEFAULT 0 NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"consumed_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "windows_offline_download_refs_reference_hash_unique" UNIQUE("reference_hash")
);
--> statement-breakpoint
ALTER TABLE "windows_offline_download_refs" ADD CONSTRAINT "windows_offline_download_refs_classroom_id_classrooms_id_fk" FOREIGN KEY ("classroom_id") REFERENCES "public"."classrooms"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "windows_offline_download_refs" ADD CONSTRAINT "windows_offline_download_refs_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "windows_offline_download_refs_expires_idx" ON "windows_offline_download_refs" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "windows_offline_download_refs_classroom_idx" ON "windows_offline_download_refs" USING btree ("classroom_id","created_at");