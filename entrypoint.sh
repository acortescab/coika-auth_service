#!/bin/bash
set -e

# Production applies migrations in a separate step (scripts/deploy.sh) and sets RUN_MIGRATIONS=false.
# Dev / docker compose keep the default and migrate on start.
if [ "${RUN_MIGRATIONS:-true}" = "true" ]; then
  echo "Running database migrations..."
  alembic upgrade head
  echo "Migrations completed"
fi

echo "Starting app..."
exec "$@"