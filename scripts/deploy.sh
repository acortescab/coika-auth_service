#!/bin/bash
# Deploys IMAGE_TAG on the API EC2 host (piped over ssh: `bash -s < scripts/deploy.sh`).
# PostgreSQL runs on its own host and is reached through DATABASE_URL_READER / DATABASE_URL_WRITER;
# this script only manages the API container.
#
# State files in ~/codename_rats-auth_service:
#   .current-image-tag   tag of the image that is running AND passed the health check
#   .previous-image-tag  the tag that was current before it (target of rollback.sh)
set -euo pipefail

# Everything lives in main() so bash parses the whole script before running any of it, and stdin is
# closed for all commands: when the script is piped over ssh (`bash -s`), a command that reads stdin
# would otherwise swallow the rest of the script and end it silently with exit code 0.
main() {
  exec < /dev/null

  : "${ECR_REGISTRY:?ECR_REGISTRY is required}"
  : "${ECR_REPOSITORY:?ECR_REPOSITORY is required}"
  : "${IMAGE_TAG:?IMAGE_TAG is required}"

  SSM_PREFIX="${SSM_PREFIX:-/coika/auth_service}"
  HEALTH_URL="${HEALTH_URL:-http://localhost:8000/v0/health/}"
  HEALTH_RETRIES="${HEALTH_RETRIES:-30}"
  CONTAINER_NAME="api"

  mkdir -p ~/codename_rats-auth_service
  cd ~/codename_rats-auth_service

  # Reads the runtime configuration from SSM Parameter Store with the instance role (nothing secret is
  # sent over ssh or stored on disk). A missing required parameter aborts before the running container
  # is touched. The OTLP endpoint is optional: empty disables telemetry.
  load_params() {
    ssm_get() {
      aws ssm get-parameter --region eu-west-1 --name "$SSM_PREFIX/$1" --with-decryption \
        --query Parameter.Value --output text
    }
    SECRET_KEY="$(ssm_get app/JWT_PRIVATE_KEY)"
    OTEL_EXPORTER_OTLP_ENDPOINT="$(ssm_get app/OTEL_EXPORTER_OTLP_ENDPOINT 2> /dev/null || true)"

    # The database URL is built from the db/* parameters (host and port are published by Terraform);
    # the password is URL-encoded so special characters cannot break the URL.
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
    # No read replica yet: the reader uses the same database.
    DATABASE_URL_READER="$DATABASE_URL_WRITER"
    unset DB_USER DB_PASSWORD DB_NAME DB_HOST DB_PORT
    export SECRET_KEY DATABASE_URL_READER DATABASE_URL_WRITER OTEL_EXPORTER_OTLP_ENDPOINT
  }

  # Replaces the running container with one started from the given tag.
  run_api() {
    # Migration from the old docker compose stack: its api container still holds port 8000. Only the api
    # service is removed; the old db container and its volume are left alone (nothing is deleted with data).
    docker ps -aq --filter "label=com.docker.compose.project=codename_rats-auth_service" \
      --filter "label=com.docker.compose.service=api" | xargs -r docker rm -f > /dev/null
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
      "$ECR_REGISTRY/$ECR_REPOSITORY:$1"
  }

  wait_healthy() {
    for _ in $(seq 1 "$HEALTH_RETRIES"); do
      if curl -fsS "$HEALTH_URL" > /dev/null 2>&1; then
        return 0
      fi
      sleep 2
    done
    return 1
  }

  aws ecr get-login-password --region eu-west-1 | docker login --username AWS --password-stdin "$ECR_REGISTRY"

  PREVIOUS_TAG=""
  if [ -f .current-image-tag ]; then
    PREVIOUS_TAG="$(cat .current-image-tag)"
  fi

  echo "Info: Deploying image tag $IMAGE_TAG"
  load_params
  docker pull "$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG"
  run_api "$IMAGE_TAG"

  if wait_healthy; then
    if [ -n "$PREVIOUS_TAG" ] && [ "$PREVIOUS_TAG" != "$IMAGE_TAG" ]; then
      echo "$PREVIOUS_TAG" > .previous-image-tag
    fi
    echo "$IMAGE_TAG" > .current-image-tag
    echo "Success: $IMAGE_TAG is healthy"
    exit 0
  fi

  echo "Error: $IMAGE_TAG did not become healthy at $HEALTH_URL"
  docker logs --tail 50 "$CONTAINER_NAME" || true

  # Put the last known-good image back (image only; the database is left untouched).
  if [ -n "$PREVIOUS_TAG" ]; then
    echo "Info: Reverting to previous image $PREVIOUS_TAG"
    run_api "$PREVIOUS_TAG"
    if wait_healthy; then
      echo "Info: Previous image $PREVIOUS_TAG is healthy again"
    else
      echo "Error: Previous image $PREVIOUS_TAG is not healthy either; manual intervention required"
    fi
  else
    echo "Error: No previous image to revert to; manual intervention required"
  fi

  exit 1
}

main "$@"
