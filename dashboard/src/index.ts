/**
 * OpenPath - Strict Internet Access Control
 * Copyright (C) 2025 OpenPath Authors
 *
 * Dashboard Server
 */

import { logger } from './lib/logger.js';
import { createDashboardApp } from './app.js';

const PORT = process.env.PORT ?? 3001;

const app = createDashboardApp({
  cookieSecure: process.env.NODE_ENV === 'production',
});

if (process.env.NODE_ENV !== 'test') {
  app.listen(PORT, () => {
    logger.info(`OpenPath Dashboard running on http://localhost:${PORT.toString()}`);
    logger.info(`API URL: ${process.env.API_URL ?? 'http://localhost:3000'}`);
  });
}

export { createDashboardApp };
export default app;
