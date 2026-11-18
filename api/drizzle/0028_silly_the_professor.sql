CREATE TABLE "agent_release_files" (
	"build" varchar(64) NOT NULL,
	"path" varchar(512) NOT NULL,
	"sha256" varchar(64) NOT NULL,
	"size" integer NOT NULL,
	"content" "bytea" NOT NULL,
	CONSTRAINT "agent_release_files_build_path_pk" PRIMARY KEY("build","path")
);
--> statement-breakpoint
CREATE TABLE "agent_releases" (
	"build" varchar(64) PRIMARY KEY NOT NULL,
	"ring" varchar(20) DEFAULT 'canary' NOT NULL,
	"source_sha" varchar(64) NOT NULL,
	"signature" text NOT NULL,
	"status" varchar(20) DEFAULT 'active' NOT NULL,
	"file_count" integer NOT NULL,
	"published_at" timestamp with time zone DEFAULT now(),
	"retired_at" timestamp with time zone,
	CONSTRAINT "agent_releases_ring_check" CHECK ("agent_releases"."ring" IN ('canary')),
	CONSTRAINT "agent_releases_status_check" CHECK ("agent_releases"."status" IN ('active', 'retired'))
);
--> statement-breakpoint
ALTER TABLE "machines" ADD COLUMN "agent_ring" varchar(20) DEFAULT 'stable' NOT NULL;--> statement-breakpoint
ALTER TABLE "agent_release_files" ADD CONSTRAINT "agent_release_files_build_agent_releases_build_fk" FOREIGN KEY ("build") REFERENCES "public"."agent_releases"("build") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "agent_releases_ring_status_published_idx" ON "agent_releases" USING btree ("ring","status","published_at");--> statement-breakpoint
ALTER TABLE "machines" ADD CONSTRAINT "machines_agent_ring_check" CHECK ("machines"."agent_ring" IN ('stable', 'canary'));