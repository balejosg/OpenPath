# Group Role Join Table Plan

> Status: maintained technical plan
> Applies to: OpenPath API
> Last verified: 2026-05-16
> Source of truth: `api/src/db/schema.ts`, `api/src/lib/role-storage-command.ts`, `api/src/lib/role-storage-query.ts`

## Problem

Role group membership is currently stored as `roles.group_ids text[]`. This makes
simple reads compact, but it keeps group references outside normal relational
integrity. Deleting a group can leave stale role `groupIds` unless every delete
path explicitly cleans the array.

The short-term integrity guard is `removeGroupFromAllRoles(groupId)`, invoked by
the group deletion service after successful group deletion. The long-term target
is a normalized join table so PostgreSQL can enforce the relationship.

## Target Model

Add a table equivalent to:

```sql
CREATE TABLE role_groups (
  role_id text NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  group_id text NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  created_at timestamp NOT NULL DEFAULT now(),
  PRIMARY KEY (role_id, group_id)
);
```

Required indexes:

- `role_groups_role_id_idx` for loading a role's approval groups.
- `role_groups_group_id_idx` for group deletion, group impact reports, and admin
  cleanup tooling.

The existing `roles.group_ids` array remains the compatibility source during the
migration window.

## Migration Phases

1. Add `role_groups` with foreign keys and indexes.
2. Backfill from `roles.group_ids`, ignoring blank and duplicate values.
3. Add dual writes in role command helpers:
   - `assignRole`
   - `updateRoleGroups`
   - `addGroupsToRole`
   - `removeGroupsFromRole`
   - `removeGroupFromAllRoles`
4. Shift role query helpers to read from `role_groups`, preserving the external
   `groupIds: string[]` API shape.
5. Add a readiness verifier that compares each role's array values with
   `role_groups` rows and fails on drift.
6. After one release window with clean verifier results, remove writes to
   `roles.group_ids`.
7. Drop `roles.group_ids` and the GIN index in a later migration.

## Compatibility Rules

- Public API and JWT role payloads continue to expose `groupIds: string[]`.
- Admin roles keep existing semantics: an admin can approve all groups regardless
  of stored group memberships.
- Missing groups in legacy arrays must not block migration; the backfill should
  report them and skip invalid join rows.
- OpenPath must not gain any ClassroomPath-specific table, environment variable,
  or tenant assumption.

## Verification

Each phase needs local API verification before broader gates:

- Unit coverage for role command helpers.
- Integration coverage for assigning roles, listing teachers, revoking roles,
  and deleting groups.
- A migration verifier covering duplicate group IDs, missing groups, empty
  arrays, and admin roles.
- Typecheck after updating storage interfaces.

Do not combine the destructive cleanup phase with the initial join-table
introduction. The first migration must be reversible while array reads remain
available.
