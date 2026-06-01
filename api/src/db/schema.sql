CREATE TABLE IF NOT EXISTS "classrooms" (
	"id" varchar(50) PRIMARY KEY NOT NULL,
	"name" varchar(100) NOT NULL,
	"display_name" varchar(255) NOT NULL,
	"default_group_id" varchar(50),
	"active_group_id" varchar(50),
	"captive_portal_domains" text[] DEFAULT '{}'::text[] NOT NULL,
	"created_at" timestamp with time zone DEFAULT now(),
	"updated_at" timestamp with time zone DEFAULT now(),
	CONSTRAINT "classrooms_name_unique" UNIQUE("name")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "dashboard_users" (
	"id" varchar(50) PRIMARY KEY NOT NULL,
	"username" varchar(100) NOT NULL,
	"password_hash" varchar(255) NOT NULL,
	"role" varchar(50) DEFAULT 'admin',
	"created_at" timestamp with time zone DEFAULT now(),
	"updated_at" timestamp with time zone DEFAULT now(),
	CONSTRAINT "dashboard_users_username_unique" UNIQUE("username")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "health_reports" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"hostname" varchar(255) NOT NULL,
	"status" varchar(50) NOT NULL,
	"dnsmasq_running" integer,
	"dns_resolving" integer,
	"fail_count" integer DEFAULT 0,
	"actions" text,
	"version" varchar(50),
	"reported_at" timestamp with time zone DEFAULT now()
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "health_reports_hostname_reported_at_idx" ON "health_reports" ("hostname","reported_at");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "machines" (
	"id" varchar(50) PRIMARY KEY NOT NULL,
	"hostname" varchar(255) NOT NULL,
	"classroom_id" varchar(50),
	"version" varchar(50) DEFAULT 'unknown',
	"last_seen" timestamp with time zone DEFAULT now(),
	"download_token_hash" varchar(64),
	"download_token_last_rotated_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now(),
	"updated_at" timestamp with time zone DEFAULT now(),
	CONSTRAINT "machines_hostname_unique" UNIQUE("hostname"),
	CONSTRAINT "machines_download_token_hash_unique" UNIQUE("download_token_hash")
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "machines_classroom_created_idx" ON "machines" ("classroom_id","created_at");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "push_subscriptions" (
	"id" varchar(50) PRIMARY KEY NOT NULL,
	"user_id" varchar(50) NOT NULL,
	"group_ids" text[] NOT NULL,
	"endpoint" text NOT NULL,
	"p256dh" text NOT NULL,
	"auth" text NOT NULL,
	"user_agent" text,
	"created_at" timestamp with time zone DEFAULT now(),
	CONSTRAINT "push_subscriptions_endpoint_unique" UNIQUE("endpoint")
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "push_subscriptions_user_id_idx" ON "push_subscriptions" ("user_id");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "push_subscriptions_group_ids_gin_idx" ON "push_subscriptions" USING gin ("group_ids");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "requests" (
	"id" varchar(50) PRIMARY KEY NOT NULL,
	"domain" varchar(255) NOT NULL,
	"reason" text,
	"requester_email" varchar(255),
	"group_id" varchar(50) NOT NULL,
	"source" varchar(50) DEFAULT 'unknown',
	"machine_hostname" varchar(255),
	"origin_host" varchar(255),
	"origin_page" text,
	"client_version" varchar(50),
	"error_type" varchar(100),
	"priority" varchar(20) DEFAULT 'normal',
	"status" varchar(20) DEFAULT 'pending',
	"created_at" timestamp with time zone DEFAULT now(),
	"updated_at" timestamp with time zone DEFAULT now(),
	"resolved_at" timestamp with time zone,
	"resolved_by" varchar(255),
	"resolution_note" text
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "requests_group_created_idx" ON "requests" ("group_id","created_at");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "requests_status_created_idx" ON "requests" ("status","created_at");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "roles" (
	"id" varchar(50) PRIMARY KEY NOT NULL,
	"user_id" varchar(50) NOT NULL,
	"role" varchar(20) NOT NULL,
	"group_ids" text[],
	"created_by" varchar(50),
	"created_at" timestamp with time zone DEFAULT now(),
	"updated_at" timestamp with time zone DEFAULT now(),
	"expires_at" timestamp with time zone,
	CONSTRAINT "roles_user_id_key" UNIQUE("user_id")
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "roles_role_idx" ON "roles" ("role");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "roles_group_ids_gin_idx" ON "roles" USING gin ("group_ids");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "schedules" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"classroom_id" varchar(50) NOT NULL,
	"teacher_id" varchar(50) NOT NULL,
	"group_id" varchar(50) NOT NULL,
	"day_of_week" integer,
	"start_time" time,
	"end_time" time,
	"start_at" timestamp with time zone,
	"end_at" timestamp with time zone,
	"recurrence" varchar(20) DEFAULT 'weekly',
	"created_at" timestamp with time zone DEFAULT now(),
	"updated_at" timestamp with time zone DEFAULT now()
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "schedules_classroom_one_off_start_idx" ON "schedules" ("classroom_id","start_at");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "machine_exemptions" (
	"id" varchar(50) PRIMARY KEY NOT NULL,
	"machine_id" varchar(50) NOT NULL,
	"classroom_id" varchar(50) NOT NULL,
	"schedule_id" uuid,
	"source" varchar(20) DEFAULT 'schedule' NOT NULL,
	"reason" text,
	"created_by" varchar(50),
	"created_at" timestamp with time zone DEFAULT now(),
	"expires_at" timestamp with time zone NOT NULL,
	CONSTRAINT "machine_exemptions_source_schedule_id_check" CHECK ("source" IN ('schedule', 'operational') AND (("source" = 'schedule' AND "schedule_id" IS NOT NULL) OR ("source" = 'operational' AND "schedule_id" IS NULL)))
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "machine_exemptions_machine_schedule_expires_key" ON "machine_exemptions" ("machine_id","schedule_id","expires_at") WHERE "source" = 'schedule';
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "machine_exemptions_machine_operational_expires_key" ON "machine_exemptions" ("machine_id","expires_at") WHERE "source" = 'operational' AND "schedule_id" IS NULL;
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "machine_exemptions_classroom_expires_idx" ON "machine_exemptions" ("classroom_id","expires_at");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "machine_exemptions_machine_expires_idx" ON "machine_exemptions" ("machine_id","expires_at");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "settings" (
	"key" varchar(100) PRIMARY KEY NOT NULL,
	"value" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now(),
	"updated_at" timestamp with time zone DEFAULT now()
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "tokens" (
	"id" varchar(50) PRIMARY KEY NOT NULL,
	"user_id" varchar(50) NOT NULL,
	"token_hash" varchar(255) NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"created_at" timestamp with time zone DEFAULT now()
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "tokens_expires_at_idx" ON "tokens" ("expires_at");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "users" (
	"id" varchar(50) PRIMARY KEY NOT NULL,
	"email" varchar(255) NOT NULL,
	"name" varchar(255) NOT NULL,
	"password_hash" varchar(255),
	"google_id" varchar(255),
	"is_active" boolean DEFAULT true NOT NULL,
	"email_verified" boolean DEFAULT false NOT NULL,
	"created_at" timestamp with time zone DEFAULT now(),
	"updated_at" timestamp with time zone DEFAULT now(),
	CONSTRAINT "users_email_unique" UNIQUE("email"),
	CONSTRAINT "users_google_id_unique" UNIQUE("google_id")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "whitelist_groups" (
	"id" varchar(50) PRIMARY KEY NOT NULL,
	"name" varchar(100) NOT NULL,
	"display_name" varchar(255) NOT NULL,
	"enabled" integer DEFAULT 1 NOT NULL,
	"visibility" varchar(20) DEFAULT 'private' NOT NULL,
	"owner_user_id" varchar(50),
	"created_at" timestamp with time zone DEFAULT now(),
	"updated_at" timestamp with time zone DEFAULT now(),
	CONSTRAINT "whitelist_groups_name_unique" UNIQUE("name")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "whitelist_rules" (
	"id" varchar(50) PRIMARY KEY NOT NULL,
	"group_id" varchar(50) NOT NULL,
	"type" varchar(50) NOT NULL,
	"value" varchar(500) NOT NULL,
	"source" varchar(50) DEFAULT 'manual' NOT NULL,
	"comment" text,
	"created_at" timestamp with time zone DEFAULT now(),
	CONSTRAINT "whitelist_rules_group_type_value_key" UNIQUE("group_id","type","value")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "password_reset_tokens" (
	"id" varchar(50) PRIMARY KEY NOT NULL,
	"user_id" varchar(50) NOT NULL,
	"token_hash" varchar(255) NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"created_at" timestamp with time zone DEFAULT now()
);

--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "password_reset_tokens_user_expires_idx" ON "password_reset_tokens" ("user_id","expires_at");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "email_verification_tokens" (
	"id" varchar(50) PRIMARY KEY NOT NULL,
	"user_id" varchar(50) NOT NULL,
	"token_hash" varchar(255) NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"created_at" timestamp with time zone DEFAULT now()
);

--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "email_verification_tokens_user_expires_idx" ON "email_verification_tokens" ("user_id","expires_at");
--> statement-breakpoint
DO $$ BEGIN
    ALTER TABLE "machines" ADD CONSTRAINT "machines_classroom_id_classrooms_id_fk" FOREIGN KEY ("classroom_id") REFERENCES "public"."classrooms"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
DO $$ BEGIN
    ALTER TABLE "push_subscriptions" ADD CONSTRAINT "push_subscriptions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
DO $$ BEGIN
    ALTER TABLE "roles" ADD CONSTRAINT "roles_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
DO $$ BEGIN
    ALTER TABLE "roles" ADD CONSTRAINT "roles_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
DO $$ BEGIN
    ALTER TABLE "schedules" ADD CONSTRAINT "schedules_classroom_id_classrooms_id_fk" FOREIGN KEY ("classroom_id") REFERENCES "public"."classrooms"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
DO $$ BEGIN
    ALTER TABLE "schedules" ADD CONSTRAINT "schedules_teacher_id_users_id_fk" FOREIGN KEY ("teacher_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
DO $$ BEGIN
	ALTER TABLE "machine_exemptions" ADD CONSTRAINT "machine_exemptions_machine_id_machines_id_fk" FOREIGN KEY ("machine_id") REFERENCES "public"."machines"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
	WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
DO $$ BEGIN
	ALTER TABLE "machine_exemptions" ADD CONSTRAINT "machine_exemptions_classroom_id_classrooms_id_fk" FOREIGN KEY ("classroom_id") REFERENCES "public"."classrooms"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
	WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
DO $$ BEGIN
	ALTER TABLE "machine_exemptions" ADD CONSTRAINT "machine_exemptions_schedule_id_schedules_id_fk" FOREIGN KEY ("schedule_id") REFERENCES "public"."schedules"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
	WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
DO $$ BEGIN
	ALTER TABLE "classrooms" ADD CONSTRAINT "classrooms_default_group_id_whitelist_groups_id_fk" FOREIGN KEY ("default_group_id") REFERENCES "public"."whitelist_groups"("id") ON DELETE set null ON UPDATE no action;
EXCEPTION
	WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
DO $$ BEGIN
	ALTER TABLE "classrooms" ADD CONSTRAINT "classrooms_active_group_id_whitelist_groups_id_fk" FOREIGN KEY ("active_group_id") REFERENCES "public"."whitelist_groups"("id") ON DELETE set null ON UPDATE no action;
EXCEPTION
	WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
DO $$ BEGIN
	ALTER TABLE "machine_exemptions" ADD CONSTRAINT "machine_exemptions_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;
EXCEPTION
	WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
DO $$ BEGIN
	ALTER TABLE "requests" ADD CONSTRAINT "requests_group_id_whitelist_groups_id_fk" FOREIGN KEY ("group_id") REFERENCES "public"."whitelist_groups"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
	WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
DO $$ BEGIN
	ALTER TABLE "schedules" ADD CONSTRAINT "schedules_group_id_whitelist_groups_id_fk" FOREIGN KEY ("group_id") REFERENCES "public"."whitelist_groups"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
	WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
DO $$ BEGIN
	ALTER TABLE "email_verification_tokens" ADD CONSTRAINT "email_verification_tokens_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
	WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
DO $$ BEGIN
    ALTER TABLE "tokens" ADD CONSTRAINT "tokens_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
DO $$ BEGIN
	ALTER TABLE "whitelist_groups" ADD CONSTRAINT "whitelist_groups_owner_user_id_users_id_fk" FOREIGN KEY ("owner_user_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;
EXCEPTION
	WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
DO $$ BEGIN
    ALTER TABLE "whitelist_rules" ADD CONSTRAINT "whitelist_rules_group_id_whitelist_groups_id_fk" FOREIGN KEY ("group_id") REFERENCES "public"."whitelist_groups"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;
--> statement-breakpoint
DO $$ BEGIN
    ALTER TABLE "password_reset_tokens" ADD CONSTRAINT "password_reset_tokens_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;
