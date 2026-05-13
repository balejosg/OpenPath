import { sql } from 'drizzle-orm';

import { db } from '../../src/db/index.js';
import { seedBaselineWhitelistGroups } from '../fixtures.js';

export async function ensureSchedulesOneOffSchema(): Promise<void> {
  const ensureSchedules = [
    'CREATE TABLE IF NOT EXISTS "schedules" (\n' +
      '  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,\n' +
      '  "classroom_id" varchar(50) NOT NULL,\n' +
      '  "teacher_id" varchar(50) NOT NULL,\n' +
      '  "group_id" varchar(100) NOT NULL,\n' +
      '  "day_of_week" integer,\n' +
      '  "start_time" time,\n' +
      '  "end_time" time,\n' +
      '  "start_at" timestamp with time zone,\n' +
      '  "end_at" timestamp with time zone,\n' +
      '  "recurrence" varchar(20) DEFAULT \'weekly\',\n' +
      '  "created_at" timestamp with time zone DEFAULT now(),\n' +
      '  "updated_at" timestamp with time zone DEFAULT now()\n' +
      ');',
    'ALTER TABLE "schedules" ADD COLUMN IF NOT EXISTS "start_at" timestamp with time zone;',
    'ALTER TABLE "schedules" ADD COLUMN IF NOT EXISTS "end_at" timestamp with time zone;',
    'ALTER TABLE "schedules" ALTER COLUMN "day_of_week" DROP NOT NULL;',
    'ALTER TABLE "schedules" ALTER COLUMN "start_time" DROP NOT NULL;',
    'ALTER TABLE "schedules" ALTER COLUMN "end_time" DROP NOT NULL;',
  ];

  for (const stmt of ensureSchedules) {
    await db.execute(sql.raw(stmt));
  }
}

async function ensureMachineExemptionsSchema(): Promise<void> {
  const ensureMachineExemptions = [
    'CREATE TABLE IF NOT EXISTS "machine_exemptions" (\n' +
      '  "id" varchar(50) PRIMARY KEY NOT NULL,\n' +
      '  "machine_id" varchar(50) NOT NULL,\n' +
      '  "classroom_id" varchar(50) NOT NULL,\n' +
      '  "schedule_id" uuid,\n' +
      '  "source" varchar(20) DEFAULT \'schedule\' NOT NULL,\n' +
      '  "reason" text,\n' +
      '  "created_by" varchar(50),\n' +
      '  "created_at" timestamp with time zone DEFAULT now(),\n' +
      '  "expires_at" timestamp with time zone NOT NULL,\n' +
      '  CONSTRAINT "machine_exemptions_source_schedule_id_check" CHECK ("source" IN (\'schedule\', \'operational\') AND (("source" = \'schedule\' AND "schedule_id" IS NOT NULL) OR ("source" = \'operational\' AND "schedule_id" IS NULL)))\n' +
      ');',
    'ALTER TABLE "machine_exemptions" ALTER COLUMN "schedule_id" DROP NOT NULL;',
    'ALTER TABLE "machine_exemptions" ADD COLUMN IF NOT EXISTS "source" varchar(20) DEFAULT \'schedule\' NOT NULL;',
    'ALTER TABLE "machine_exemptions" ADD COLUMN IF NOT EXISTS "reason" text;',
    'ALTER TABLE "machine_exemptions" DROP CONSTRAINT IF EXISTS "machine_exemptions_machine_schedule_expires_key";',
    'DROP INDEX IF EXISTS "machine_exemptions_machine_schedule_expires_key";',
    'DROP INDEX IF EXISTS "machine_exemptions_machine_operational_expires_key";',
    'CREATE UNIQUE INDEX IF NOT EXISTS "machine_exemptions_machine_schedule_expires_key" ON "machine_exemptions" ("machine_id","schedule_id","expires_at") WHERE "source" = \'schedule\';',
    'CREATE UNIQUE INDEX IF NOT EXISTS "machine_exemptions_machine_operational_expires_key" ON "machine_exemptions" ("machine_id","expires_at") WHERE "source" = \'operational\' AND "schedule_id" IS NULL;',
    'ALTER TABLE "machine_exemptions" DROP CONSTRAINT IF EXISTS "machine_exemptions_source_schedule_id_check";',
    'ALTER TABLE "machine_exemptions" ADD CONSTRAINT "machine_exemptions_source_schedule_id_check" CHECK ("source" IN (\'schedule\', \'operational\') AND (("source" = \'schedule\' AND "schedule_id" IS NOT NULL) OR ("source" = \'operational\' AND "schedule_id" IS NULL)));',
    'CREATE INDEX IF NOT EXISTS "machine_exemptions_classroom_expires_idx" ON "machine_exemptions" ("classroom_id","expires_at");',
    'CREATE INDEX IF NOT EXISTS "machine_exemptions_machine_expires_idx" ON "machine_exemptions" ("machine_id","expires_at");',
    'DO $$ BEGIN\n' +
      '  ALTER TABLE "machine_exemptions" ADD CONSTRAINT "machine_exemptions_machine_id_machines_id_fk" FOREIGN KEY ("machine_id") REFERENCES "public"."machines"("id") ON DELETE cascade ON UPDATE no action;\n' +
      'EXCEPTION\n' +
      '  WHEN duplicate_object THEN NULL;\n' +
      'END $$;',
    'DO $$ BEGIN\n' +
      '  ALTER TABLE "machine_exemptions" ADD CONSTRAINT "machine_exemptions_classroom_id_classrooms_id_fk" FOREIGN KEY ("classroom_id") REFERENCES "public"."classrooms"("id") ON DELETE cascade ON UPDATE no action;\n' +
      'EXCEPTION\n' +
      '  WHEN duplicate_object THEN NULL;\n' +
      'END $$;',
    'DO $$ BEGIN\n' +
      '  ALTER TABLE "machine_exemptions" ADD CONSTRAINT "machine_exemptions_schedule_id_schedules_id_fk" FOREIGN KEY ("schedule_id") REFERENCES "public"."schedules"("id") ON DELETE cascade ON UPDATE no action;\n' +
      'EXCEPTION\n' +
      '  WHEN duplicate_object THEN NULL;\n' +
      'END $$;',
    'DO $$ BEGIN\n' +
      '  ALTER TABLE "machine_exemptions" ADD CONSTRAINT "machine_exemptions_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;\n' +
      'EXCEPTION\n' +
      '  WHEN duplicate_object THEN NULL;\n' +
      'END $$;',
  ];

  for (const stmt of ensureMachineExemptions) {
    await db.execute(sql.raw(stmt));
  }
}

async function ensureMachinesSchema(): Promise<void> {
  await db.execute(
    sql.raw('ALTER TABLE "machines" ADD COLUMN IF NOT EXISTS "reported_hostname" varchar(255);')
  );
}

async function ensureEmailVerificationSchema(): Promise<void> {
  const statements = [
    'DO $$ BEGIN\n' +
      '  CREATE TABLE IF NOT EXISTS "email_verification_tokens" (\n' +
      '    "id" varchar(50) PRIMARY KEY NOT NULL,\n' +
      '    "user_id" varchar(50) NOT NULL,\n' +
      '    "token_hash" varchar(255) NOT NULL,\n' +
      '    "expires_at" timestamp with time zone NOT NULL,\n' +
      '    "created_at" timestamp with time zone DEFAULT now()\n' +
      '  );\n' +
      'EXCEPTION\n' +
      '  WHEN duplicate_table OR unique_violation THEN NULL;\n' +
      'END $$;',
    'DO $$ BEGIN\n' +
      '  ALTER TABLE "email_verification_tokens" ADD CONSTRAINT "email_verification_tokens_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;\n' +
      'EXCEPTION\n' +
      '  WHEN duplicate_object THEN NULL;\n' +
      'END $$;',
  ];

  for (const stmt of statements) {
    await db.execute(sql.raw(stmt));
  }
}

async function ensureGroupForeignKeyConstraints(): Promise<void> {
  const statements = [
    'ALTER TABLE "classrooms" DROP CONSTRAINT IF EXISTS "classrooms_default_group_id_whitelist_groups_id_fk";',
    'DO $$ BEGIN\n' +
      '  ALTER TABLE "classrooms" ADD CONSTRAINT "classrooms_default_group_id_whitelist_groups_id_fk" FOREIGN KEY ("default_group_id") REFERENCES "public"."whitelist_groups"("id") ON DELETE set null ON UPDATE no action;\n' +
      'EXCEPTION\n' +
      '  WHEN duplicate_object THEN NULL;\n' +
      'END $$;',
    'ALTER TABLE "classrooms" DROP CONSTRAINT IF EXISTS "classrooms_active_group_id_whitelist_groups_id_fk";',
    'DO $$ BEGIN\n' +
      '  ALTER TABLE "classrooms" ADD CONSTRAINT "classrooms_active_group_id_whitelist_groups_id_fk" FOREIGN KEY ("active_group_id") REFERENCES "public"."whitelist_groups"("id") ON DELETE set null ON UPDATE no action;\n' +
      'EXCEPTION\n' +
      '  WHEN duplicate_object THEN NULL;\n' +
      'END $$;',
    'ALTER TABLE "requests" DROP CONSTRAINT IF EXISTS "requests_group_id_whitelist_groups_id_fk";',
    'DO $$ BEGIN\n' +
      '  ALTER TABLE "requests" ADD CONSTRAINT "requests_group_id_whitelist_groups_id_fk" FOREIGN KEY ("group_id") REFERENCES "public"."whitelist_groups"("id") ON DELETE cascade ON UPDATE no action;\n' +
      'EXCEPTION\n' +
      '  WHEN duplicate_object THEN NULL;\n' +
      'END $$;',
    'ALTER TABLE "schedules" DROP CONSTRAINT IF EXISTS "schedules_group_id_whitelist_groups_id_fk";',
    'DO $$ BEGIN\n' +
      '  ALTER TABLE "schedules" ADD CONSTRAINT "schedules_group_id_whitelist_groups_id_fk" FOREIGN KEY ("group_id") REFERENCES "public"."whitelist_groups"("id") ON DELETE cascade ON UPDATE no action;\n' +
      'EXCEPTION\n' +
      '  WHEN duplicate_object THEN NULL;\n' +
      'END $$;',
  ];

  for (const stmt of statements) {
    await db.execute(sql.raw(stmt));
  }
}

export async function ensureTestSchema(): Promise<void> {
  await ensureSchedulesOneOffSchema();
  await ensureMachineExemptionsSchema();
  await ensureMachinesSchema();
  await ensureEmailVerificationSchema();
  await ensureGroupForeignKeyConstraints();
  await seedBaselineWhitelistGroups();
}

export async function ensureCanonicalGroupForeignKeys(): Promise<void> {
  await ensureGroupForeignKeyConstraints();
}
