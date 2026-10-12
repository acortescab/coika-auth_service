#!/bin/bash
# Rolls the API container back to the previous image (piped over ssh: `bash -s < scripts/rollback.sh`).
#
# Only the image is rolled back; the database lives on its own host and is left as it is, so no user
# data is lost. If a failed release ran a destructive migration, restore the dump on the DB host.
set -euo pipefail

# Everything lives in main() so bash parses the whole script before running any of it, and stdin is
# closed for all commands: when the script is piped over ssh (`bash -s`), a command that reads stdin
# would otherwise swallow the rest of the script and end it silently with exit code 0.
main() {
  exec < /dev/null

  : "${ECR_REGISTRY:?ECR_REGISTRY is required}"
  : "${ECR_REPOSITORY:?ECR_REPOSITORY is required}"

  SSM_PREFIX="${SSM_PREFIX:-/coika/auth_service}"
  HEALTH_URL="${HEALTH_URL:-http://localhost:8000/v0/health/}"
  HEALTH_RETRIES="${HEALTH_RETRIES:-30}"
  CONTAINER_NAME="api"

  mkdir -p ~/codename_rats-auth_service
  cd ~/codename_rats-auth_service

  if [ ! -f .previous-image-tag ]; then
    echo "Error: .previous-image-tag not found; there is no earlier release to roll back to."
    exit 1
  fi

  ROLLBACK_TAG="$(cat .previous-image-tag)"

  if [ -z "$ROLLBACK_TAG" ]; then
    echo "Error: Rollback tag is empty."
    exit 1
  fi

  aws ecr get-login-password --region eu-west-1 | docker login --username AWS --password-stdin "$ECR_REGISTRY"

  echo "Info: Rolling back to image: $ROLLBACK_TAG"

  # Runtime configuration from SSM Parameter Store (instance role). OTLP endpoint is optional.
  ssm_get() {
    aws ssm get-parameter --region eu-west-1 --name "$SSM_PREFIX/$1" --with-decryption \
      --query Parameter.Value --output text
  }
  SECRET_KEY="$(ssm_get app/JWT_PRIVATE_KEY)"
  OTEL_EXPORTER_OTLP_ENDPOINT="$(ssm_get app/OTEL_EXPORTER_OTLP_ENDPOINT 2> /dev/null || true)"

  # Same URL construction as deploy.sh: db/* parameters, password URL-encoded.
  DB_USER="$(ssm_get db/POSTGRES_USER)"
  DB_PASSWORD="$(ssm_get db/POSTGRES_PASSWORD)"
  DB_NAME="$(ssm_get db/POSTGRES_DB)"
  DB_HOST="$(ssm_get db/DB_HOST)"
  DB_PORT="$(ssm_get db/DB_PORT)"
  export DB_USER DB_PASSWORD DB_NAME DB_HOST DB_PORT
  DATABASE_URL_WRITER="$(python3 - <<'PY'
import os
from urllib.parse import quote
e = os.environ
print(f"postgresql://{quote(e['DB_USER'], safe='')}:{quote(e['DB_PASSWORD'], safe='')}@{e['DB_HOST']}:{e['DB_PORT']}/{e['DB_NAME']}")
PY
)"
  DATABASE_URL_READER="$DATABASE_URL_WRITER"
  unset DB_USER DB_PASSWORD DB_NAME DB_HOST DB_PORT
  export SECRET_KEY DATABASE_URL_READER DATABASE_URL_WRITER OTEL_EXPORTER_OTLP_ENDPOINT

  docker pull "$ECR_REGISTRY/$ECR_REPOSITORY:$ROLLBACK_TAG"
  docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p 8000:8000 \
    -e ENV=prod \
    -e SECRET_KEY \
    -e DATABASE_URL_READER \
    -e DATABASE_URL_WRITER \
    -e OTEL_EXPORTER_OTLP_ENDPOINT \
    "$ECR_REGISTRY/$ECR_REPOSITORY:$ROLLBACK_TAG"

  for _ in $(seq 1 "$HEALTH_RETRIES"); do
    if curl -fsS "$HEALTH_URL" > /dev/null 2>&1; then
      # the release we rolled back to is now current; nothing earlier is known-good
      echo "$ROLLBACK_TAG" > .current-image-tag
      rm -f .previous-image-tag
      echo "Success: Application rolled back to $ROLLBACK_TAG"
      exit 0
    fi
    sleep 2
  done

  echo "Error: $ROLLBACK_TAG did not become healthy after rollback; manual intervention required"
  docker logs --tail 50 "$CONTAINER_NAME" || true
  exit 1
}

main "$@"
