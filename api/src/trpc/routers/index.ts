import { router } from '../trpc.js';
import { authRouter } from './auth.js';
import { usersRouter } from './users.js';
import { requestsRouter } from './requests.js';
import { classroomsRouter } from './classrooms.js';
import { schedulesRouter } from './schedules.js';
import { pushRouter } from './push.js';
import { healthReportsRouter } from './health-reports.js';
import { setupRouter } from './setup.js';
import { healthcheckRouter } from './healthcheck.js';
import { groupsRouter } from './groups.js';
import { backupRouter } from './backup.js';
import { apiTokensRouter } from './api-tokens.js';
import { windowsOfflineInstallerRouter } from './windows-offline-installer.js';

export const appRouter = router({
  auth: authRouter,
  users: usersRouter,
  requests: requestsRouter,
  classrooms: classroomsRouter,
  schedules: schedulesRouter,
  push: pushRouter,
  healthReports: healthReportsRouter,
  setup: setupRouter,
  healthcheck: healthcheckRouter,
  groups: groupsRouter,
  backup: backupRouter,
  apiTokens: apiTokensRouter,
  windowsOfflineInstaller: windowsOfflineInstallerRouter,
});

export type AppRouter = typeof appRouter;
