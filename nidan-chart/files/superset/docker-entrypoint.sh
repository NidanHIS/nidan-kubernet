#!/bin/sh
set -e

echo "Running database migrations..."
superset db upgrade

echo "Creating admin user (if not exists)..."
superset fab create-admin \
  --username "${SUPERSET_ADMIN_USERNAME:-admin}" \
  --firstname "${SUPERSET_ADMIN_FIRSTNAME:-Superset}" \
  --lastname "${SUPERSET_ADMIN_LASTNAME:-Admin}" \
  --email "${SUPERSET_ADMIN_EMAIL:-admin@superset.local}" \
  --password "${SUPERSET_ADMIN_PASSWORD:-admin}" \
  || true

echo "Initializing Superset..."
superset init

echo "Initializing metadata (databases, datasets, charts, dashboard)..."
python3 /app/pythonpath/init_superset_metadata.py || true

echo "Starting Gunicorn..."
exec gunicorn \
  --bind 0.0.0.0:8088 \
  --workers 4 \
  --timeout 120 \
  --limit-request-line 0 \
  --limit-request-field_size 0 \
  "superset.app:create_app()"
