# coika-auth_service

[![CI](https://github.com/acortescab/coika-auth_service/actions/workflows/ci_tests.yml/badge.svg)](https://github.com/acortescab/coika-auth_service/actions/workflows/ci_tests.yml)
[![codecov](https://codecov.io/gh/acortescab/coika-auth_service/branch/main/graph/badge.svg)](https://codecov.io/gh/acortescab/coika-auth_service)

Authentication and user session service for the Coika platform.

This project provides a FastAPI-based identity service with guest login, user registration, JWT-based authentication, refresh-token rotation, account linking, and health checks. It is designed to run locally with Docker Compose and supports PostgreSQL-backed persistence through SQLAlchemy and Alembic.

## Tech Stack

- Python 3.12+
- FastAPI
- PostgreSQL
- SQLAlchemy
- Alembic
- Pydantic + Pydantic Settings
- JWT via PyJWT
- bcrypt
- Docker / Docker Compose
- pytest

## Features

- Guest login flow
- User registration and login
- JWT access token validation
- Refresh token support and rotation
- Logout and token invalidation
- Account linking for guest users
- Public player profile lookup (id and name) for other services
- Health endpoint for service checks
- Dockerized local development setup

## Architecture

The service is organized around a lightweight layered structure:

- API layer: FastAPI routers under `app/api/v0/routes`
- Services: core business logic under `app/services`
  - `AuthService`: guest login, registration, login, account linking, logout and access-token validation
  - `TokenService`: JWT and refresh-token creation, decoding, rotation and revocation
  - `LookupService`: read-only public data of players (id and name) for an authenticated caller
- Repositories: database access logic under `app/repositories`
- Models: database schema under `app/db/models`
- Core utilities: security, config, and custom exceptions under `app/core`
- Schemas: request/response validation under `app/schemas`

## Project Structure

```text
.
├── alembic/
│   ├── versions/
│   ├── env.py
│   └── README
├── app/
│   ├── api/
│   │   └── v0/
│   │       └── routes/
│   │           ├── auth.py
│   │           ├── health.py
│   │           └── players.py
│   ├── core/
│   │   ├── config.py
│   │   ├── exceptions/
│   │   └── security.py
│   ├── db/
│   │   ├── models/
│   │   ├── base.py
│   │   └── session.py
│   ├── dependencies.py
│   ├── factories.py
│   ├── main.py
│   ├── repositories/
│   ├── schemas/
│   └── services/
├── tests/
├── .gitignore
├── .github/
│   └── workflows/
│       └── ci_tests.yml
├── alembic.ini
├── docker-compose.yml
├── Dockerfile
├── entrypoint.sh
├── Makefile
├── pyproject.toml
├── pytest.ini
├── requirements.txt
└── README.md
```

## Why Is It Structured This Way?

This project intentionally separates the code into small, purpose-specific layers so that authentication logic stays predictable and testable as the service grows.

- The API layer handles HTTP concerns only: request parsing, route registration, and response formatting. It should not contain business rules or persistence logic.
- Services contain the domain behavior: login, registration, token validation, session lifecycle, and account linking. This keeps the core authentication flows in one place and makes them easier to test in isolation.
- Repositories isolate database access from the rest of the application. That allows the service layer to operate on domain concepts instead of directly mixing SQLAlchemy logic with business rules.
- Models and schema definitions clearly separate persistence concerns from request/response validation. This reduces the risk of accidentally leaking database structures into API contracts.
- Core utilities centralize reusable concerns such as settings, security helpers, and custom exceptions so that the rest of the codebase remains consistent.

The result is a service that is easier to reason about, easier to extend with new auth features, and simpler to validate with focused unit and integration tests.

## Prerequisites

Before running the project locally, make sure you have:

- Docker and Docker Compose
- Python 3.12+
- uv
- Access to a local PostgreSQL instance or use the included Docker service

## Local Development

### 1. Create environment variables

Create a `.env` file in the project root with the following values:

```env
ENV=dev
DATABASE_URL_READER=postgresql://user:pass@db:5432/db
DATABASE_URL_WRITER=postgresql://user:pass@db:5432/db
```

The application reads these values at startup through the settings loader in `app/core/config.py`.

In `dev`, `SECRET_KEY` is loaded automatically from `secrets/private_key.pem`, so you do not need to set it in `.env`.

If you set `ENV` to a non-dev value, `SECRET_KEY` must be an RSA private key in PEM format (multi-line), because tokens are signed with `RS256`. In production it comes from AWS SSM Parameter Store (see [Production](#production)).

### 2. Start the development stack

```bash
make dev-up
```

This starts:

- the PostgreSQL database service
- the FastAPI application on port `8000`

The underlying Compose file is `docker-compose.yml`, which defines the `db` and `api` services and sets the `uvicorn` command for the API container.

### 3. Stop the stack

```bash
make dev-down
```

### 4. Rebuild containers

```bash
make dev-rebuild
```

## Testing

Run lint and the test suite with Docker Compose:

```bash
docker compose run --rm api ruff check .
docker compose run --rm api pytest -q --cov=. --cov-report=xml
```

The repository CI workflow runs the same checks in GitHub Actions.

## Useful Commands

```bash
# Start dev environment
make dev-up

# Stop dev environment
make dev-down

# Rebuild services
make dev-rebuild

# Run shell inside the API container
make shell

# Open PostgreSQL shell
make shell-db

# Generate Alembic migration
make migrate msg="describe migration"

# Apply latest migrations
make update-db

# Build the API image without starting it
docker compose build api
```

## API Overview

The service exposes versioned routes under `/v0`.

### Root and JWKS

- `GET /`
- `GET /.well-known/jwks.json`

### Health

- `GET /v0/health/`

### Auth

- `POST /v0/auth/register`
- `POST /v0/auth/login`
- `POST /v0/auth/guest-login` (see [Guest login](#guest-login))
- `POST /v0/auth/refresh-token`
- `GET /v0/auth/me`
- `POST /v0/auth/logout`
- `POST /v0/auth/link-account`

### Players

- `POST /v0/players/lookup` (see [Player lookup](#player-lookup))

### Player lookup

Lets other services (e.g. the game) show player names. It requires a valid access token in the
`Authorization: Bearer` header; any authenticated player may call it.

```http
POST /v0/players/lookup
Authorization: Bearer <access_token>
Content-Type: application/json

{"ids": ["3fa85f64-5717-4562-b3fc-2c963f66afa6"]}
```

- The ids travel in the body (POST) instead of the URL: between 1 and 100 UUIDs per request.
- The response is a list of `{"id", "name"}`. Unknown ids are left out, and no private data (email, account type) is exposed.
- An invalid token, or one of a player that no longer exists, returns `401`.

### Guest login

A guest is identified by `device_id` and authenticated by a `device_secret` issued by the server:

1. First call with only `device_id`: the guest is created and the response includes a `device_secret`.
   The server stores only its hash and never returns it again, so the client must persist it
   (keychain / secure storage).
2. Every later call must send both `device_id` and `device_secret`. A missing or wrong secret returns `401`.
3. Guests created before device secrets existed claim one on their next login (the response then includes
   `device_secret`). Until that happens, `device_id` alone is accepted for them.

If a client loses its `device_secret`, that guest can no longer log in (the account can still be reached if it
was linked to an email with `/link-account`).

## Security Notes

- Keep `SECRET_KEY` private and never commit it to source control.
- Use environment variables or a local `.env` file for development only.
- In production, secrets live in AWS SSM Parameter Store and are never stored in GitHub secrets or on disk.

## License

This project is licensed under the terms described in the repository license file.

## CI/CD

`.github/workflows/ci.yml` checks pull requests to `main`:

- builds the application image
- runs `ruff check .`
- runs `pytest -q --cov=. --cov-report=xml`

This matches the Docker Compose setup used for local development and keeps CI aligned with it.

`.github/workflows/cd.yml` runs on every push to `main`: it builds and pushes the image to ECR (tagged with the
commit SHA and `latest`), deploys it to the API host over SSH with `scripts/deploy.sh`, runs the smoke tests
and, if they fail, runs `scripts/rollback.sh`.

GitHub configuration of the `prod` environment:

- Secrets: `AWS_ROLE_ARN`, `EC2_SSH_KEY`
- Variables: `ECR_REPOSITORY`, `EC2_HOST`, `EC2_USER`, `PROD_URL`

## Production

Docker Compose is only used for local development and CI. In production there are two EC2 hosts, both
provisioned by the infrastructure repository (`codename_rats-auth_service-infra`):

- **API host**: runs a single container (`api`) started with `docker run` by `scripts/deploy.sh`. There is no
  production compose file.
- **Database host**: PostgreSQL in its own EC2 with a dedicated EBS volume. How to start it and how its
  backups to S3 work is documented in the infrastructure repository (`db/README.md`).

### Configuration (SSM Parameter Store)

The API host reads its configuration at deploy time with its instance role, so the deploy sends no secret over
SSH. Prefix `/coika/auth_service` (override with `SSM_PREFIX`):

| Parameter | Used for |
| --- | --- |
| `app/JWT_PRIVATE_KEY` | `SECRET_KEY` (RSA private key in PEM) |
| `app/OTEL_EXPORTER_OTLP_ENDPOINT` | optional; without it telemetry is disabled |
| `db/POSTGRES_USER`, `db/POSTGRES_PASSWORD`, `db/POSTGRES_DB` | credentials shared with the database host |
| `db/DB_HOST`, `db/DB_PORT` | created by Terraform; address of the database host |

`DATABASE_URL_WRITER` and `DATABASE_URL_READER` are built by the deploy script from the `db/*` parameters (the
password is URL-encoded). There is no read replica yet, so both point to the same database. A missing required
parameter aborts the deploy before the running container is touched.

### Deploy and rollback

- `scripts/deploy.sh` pulls the image, replaces the `api` container and waits for `/v0/health/`. If the new
  image is not healthy it puts the previous one back. The state lives in `~/codename_rats-auth_service`
  (`.current-image-tag`, `.previous-image-tag`).
- `scripts/rollback.sh` redeploys the previous image. It never touches the database: the dumps live in S3 and
  are restored on the database host (`restore.sh` in the infrastructure repository).

