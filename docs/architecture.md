# Authentication Service Architecture

```mermaid
flowchart LR
    Client[Client App\nWeb / Mobile / API Consumer]

    subgraph API[FastAPI API Layer]
        Router[Routes\napp/api/v0/routes]
        Security[Auth Middleware & JWT\napp/core/security.py]
    end

    subgraph App[Application Layer]
        Dependencies[Dependency Providers\napp/dependencies.py]
        Factories[Service Factories\napp/factories.py]
        Services[Services\nAuthService / LookupService / TokenService]
        Schemas[Schemas\napp/schemas]
    end

    subgraph Data[Data Layer]
        Repositories[Repositories\nPlayerRepository / RefreshTokenRepository]
        Models[SQLAlchemy Models\nPlayer / RefreshToken]
        DB[(PostgreSQL)]
    end

    subgraph Infra[Infrastructure]
        Config[Settings & Config\napp/core/config.py]
        Migrations[Alembic Migrations\nalembic/versions]
        Docker["Docker Compose (dev/CI) / API container (prod)"]
    end

    Client -->|HTTP requests| Router
    Router --> Dependencies
    Dependencies --> Factories
    Factories --> Services
    Services --> Repositories
    Services --> Security
    Repositories --> Models
    Models --> DB

    Router --> Schemas
    Services --> Config
    Config --> DB

    Migrations --> DB
    Docker --> API
    Docker --> DB

    classDef client fill:#E3F2FD,stroke:#1E88E5,color:#0D47A1;
    classDef api fill:#E8F5E9,stroke:#43A047,color:#1B5E20;
    classDef app fill:#FFF3E0,stroke:#FB8C00,color:#E65100;
    classDef data fill:#F3E5F5,stroke:#8E24AA,color:#4A148C;
    classDef infra fill:#FCE4EC,stroke:#D81B60,color:#880E4F;

    class Client client;
    class Router,Security api;
    class Dependencies,Factories,Services,Schemas app;
    class Repositories,Models,DB data;
    class Config,Migrations,Docker infra;
```

## Overview

This service is a FastAPI authentication backend for the Coika platform. It handles guest login, user registration, JWT access/refresh token creation, account linking, and logout flows.

## Layers

- API layer: route handlers under app/api/v0/routes
- Service layer: business logic in app/services
- Repository layer: database access in app/repositories
- Model layer: SQLAlchemy persistence models in app/db/models
- Core layer: settings, JWT helpers, and exception handling in app/core
- Infrastructure layer: PostgreSQL, Docker, and Alembic migration tooling

## Production deployment

```mermaid
flowchart LR
    GH[GitHub Actions\nci.yml / cd.yml] -->|push image| ECR[(ECR)]
    GH -->|ssh: deploy.sh / rollback.sh| API
    subgraph VPC
        API[API host\nEC2, api container :8000]
        PG[Database host\nEC2, PostgreSQL :5432\nEBS data volume]
    end
    API -->|DATABASE_URL_*| PG
    API -.->|read config at deploy| SSM[SSM Parameter Store\n/coika/auth_service]
    PG -.->|read credentials| SSM
    API -->|pull image| ECR
    PG -->|pg_dump cron| S3[(S3 snapshots\nversioned, DR replica)]
```

- Docker Compose is used only for local development and CI. Production has no compose file: the API host runs
  one container started with `docker run` by `scripts/deploy.sh`.
- PostgreSQL runs on its own EC2 host (private subnet, data on a dedicated EBS volume). Only the API host can reach
  its port, and backups go to S3 (the infrastructure repository documents both).
- Secrets and configuration are read from SSM Parameter Store with the instance roles. The deploy builds
  `DATABASE_URL_*` from the `db/*` parameters, so credentials are stored once and never travel over SSH.
- Rollback only redeploys the previous image; data is restored explicitly on the database host.

## Request flow

1. A client calls an endpoint like /v0/auth/login or /v0/auth/refresh-token.
2. The route resolves the required service dependency.
3. The service validates credentials and issues or revokes tokens.
4. Repositories read/write player and refresh-token records.
5. The PostgreSQL database persists the resulting state.
6. Alembic migrations keep schema changes consistent across environments.

## Main responsibilities

- Guest account creation and login
- Email/password registration and login
- Access token validation and refresh token rotation
- Token revocation during logout
- Account linking from guest to registered user
- Health monitoring via /v0/health
