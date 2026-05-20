# syntax=docker/dockerfile:1.7

FROM node:20-alpine AS builder

WORKDIR /app

# Install system dependencies for native modules (bcrypt)
RUN apk add --no-cache python3 make g++

# Copy dependency manifests separately so script-only metadata changes do not
# invalidate the expensive npm install layers.
COPY package-lock.json ./
COPY package.docker.json ./package.json
COPY tsconfig.base.json ./
COPY api/package.docker.json ./api/package.json
COPY shared/package.docker.json ./shared/package.json
COPY react-spa/package.docker.json ./react-spa/package.json

# Install all dependencies
RUN --mount=type=cache,target=/root/.npm npm ci

# Copy source code
COPY api ./api
COPY shared ./shared
COPY react-spa ./react-spa
COPY windows ./windows
COPY runtime ./runtime
COPY VERSION ./VERSION

# Build shared package first
RUN npm run build --workspace=@openpath/shared

# Build API (needed for SPA types)
RUN npm run build --workspace=@openpath/api

# Build React SPA
RUN npm run build --workspace=@openpath/react-spa



# -----------------------------------------------------------------------------
# Production Stage
# -----------------------------------------------------------------------------
FROM node:20-alpine

WORKDIR /app

# Install dumb-init and build tools for native modules (bcrypt)
RUN apk add --no-cache dumb-init python3 make g++

# Copy dependency manifests
COPY package-lock.json ./
COPY package.docker.json ./package.json
COPY api/package.docker.json ./api/package.json
COPY shared/package.docker.json ./shared/package.json
COPY react-spa/package.docker.json ./react-spa/package.json

# Install production dependencies only. The mounted npm cache is ephemeral and
# not committed into the image, so cleaning it here only adds failure modes.
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev

# Restore runtime package metadata and built artifacts from the builder stage
COPY --from=builder /app/api/package.json ./api/package.json
COPY --from=builder /app/shared/package.json ./shared/package.json
COPY --from=builder /app/react-spa/package.json ./react-spa/package.json
COPY --from=builder /app/api/dist ./api/dist
COPY --from=builder /app/api/drizzle ./api/drizzle
COPY --from=builder /app/shared/dist ./shared/dist
COPY --from=builder /app/react-spa/dist ./react-spa/dist
COPY --from=builder /app/api/data ./api/data
COPY --from=builder /app/windows ./windows
COPY --from=builder /app/runtime ./runtime
COPY --from=builder /app/VERSION ./VERSION

# Copy database schema (needed for migration)
# We place it in a location where migrate.js expects it: ../src/db/schema.sql relative to dist/scripts/
COPY api/src/db/schema.sql ./api/dist/src/db/schema.sql

# Create non-root user
RUN addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001 -G nodejs && \
    chown -R nodejs:nodejs /app

USER nodejs

# Expose port
EXPOSE 3000

# Health check (API is strictly JSON, but /health might return 200 OK)
# Assuming wget works on localhost
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:3000/health || exit 1

# Use dumb-init to handle signals properly
ENTRYPOINT ["dumb-init", "--"]

# Start the compiled application
WORKDIR /app/api
CMD ["node", "dist/src/server.js"]
