# clickkart-config-repository

Centralized configuration for every ClickKart microservice, served by `clickkart-config-server`
via [Spring Cloud Config](https://spring.io/projects/spring-cloud-config).

## Branch = environment

There are exactly **four** environment branches. Each one holds only that environment's
properties files, unsuffixed:

| Branch | Environment |
|--------|-------------|
| [`dev`](../../tree/dev)   | Local/developer environment |
| [`test`](../../tree/test) | CI/automated test environment |
| [`qa`](../../tree/qa)     | QA/staging environment |
| [`prod`](../../tree/prod) | Production |

This `main` branch is **documentation only** - it holds no environment config and is never read
by any running service. It exists solely as the repo's default landing page on GitHub. (An
earlier version of this repo kept everything - all four environments - on `main`, differentiated
only by filename suffix, e.g. `clickkart-auth-service-dev.properties`. That was replaced by the
branch-per-environment layout below: it's what actually gets fetched, one config source per
environment, with no risk of editing the wrong environment's block inside a shared file.)

Each environment branch has the same file layout:

```
application.properties                       # global defaults, every service, this environment
clickkart-api-gateway.properties
clickkart-auth-service.properties
clickkart-audit-log-service.properties
```

`eureka-server` and `config-server` itself are **not** Config Server clients - they configure
themselves locally (`application-<profile>.properties` inside each service's own repo), to avoid
a circular bootstrap dependency (Config Server can't fetch its own config from Config Server).

## How a service picks its branch

Every Config Client service's local `src/main/resources/application.properties` sets:

```properties
spring.cloud.config.label=${SPRING_PROFILES_ACTIVE:dev}
```

Spring Cloud Config's `label` request parameter maps directly to a **git branch/tag**. Combined
with `SPRING_PROFILES_ACTIVE` (already set per-environment via each service's Docker/k8s env),
this means a service started with `SPRING_PROFILES_ACTIVE=qa` automatically requests
`GET /{application}/{profile}/qa` from Config Server, which resolves to the `qa` branch of this
repo - no other wiring needed. Change `SPRING_PROFILES_ACTIVE` and the service pulls from a
different branch entirely.

Config Server's own git backend config (`clickkart-config-server`'s `application.properties`)
needs no per-environment changes either - `spring.cloud.config.server.git.uri` points at this
repo once, and Spring Cloud Config Server fetches whichever branch the request's `label` asks
for automatically.

## Adding or changing a property

1. Check out the environment branch you're changing (e.g. `git checkout dev`).
2. Edit the relevant `clickkart-<service>.properties` file (or `application.properties` for a
   global default).
3. Commit and push.
4. The running service picks up the change on its next Config Server refresh (or restart, for
   properties not wired to `@RefreshScope`/`/actuator/refresh`).

To promote a change through environments (dev -> test -> qa -> prod), apply the same edit on
each branch in turn - branches are independent, not stacked, so there's no automatic fast-forward
between them. This is deliberate: a `qa` or `prod` config change should be a distinct, reviewable
commit on that branch, not an automatic side effect of a `dev` change.

## Adding a new service

1. On each of the four environment branches, add `clickkart-<new-service>.properties` with that
   environment's values (datasource host, resource limits, feature flags, etc. - see an existing
   service's file for the pattern).
2. Make sure the new service's own bootstrap `application.properties` includes
   `spring.cloud.config.label=${SPRING_PROFILES_ACTIVE:dev}` (see "How a service picks its
   branch" above) - without it, the service falls back to Config Server's
   `default-label` (`main`), which has no properties files and would leave the service running on
   nothing but its own local defaults.

## Database roles each environment must provision

Every environment's Postgres must have **one dedicated, least-privilege role per service** - never
a shared superuser. The `spring.datasource.username` defaults on every branch expect exactly these
names:

| Service | Database | Role |
|---------|----------|------|
| auth-service | `clickkart_auth` | `clickkart_auth_app` |
| notification-service | `clickkart_notification` | `clickkart_notification_app` |
| audit-log-service | `clickkart_audit_log` | `clickkart_audit_log_app` |

Each role owns exactly one database, and `CONNECT` is revoked from `PUBLIC` on the other two, so a
leaked credential for one service cannot even open a connection to another service's data - it
fails at connect time, before any query runs. Provision with:

```sql
CREATE ROLE <role> WITH LOGIN PASSWORD '<generated>';
ALTER DATABASE <db> OWNER TO <role>;
-- then, connected to <db>:
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO <role>;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO <role>;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO <role>;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO <role>;
-- and, for each of the OTHER two databases:
REVOKE CONNECT ON DATABASE <other-db> FROM PUBLIC;
GRANT  CONNECT ON DATABASE <other-db> TO <that-db's-own-role>;
```

## Secrets

No real secret values are committed on any branch, `prod` included - every credential-shaped
property is `${ENV_VAR}` with no default (or a clearly-marked dev-only fallback on `dev`/`test`),
supplied at deploy time via the platform's actual secrets manager.

Note that the datasource **password** has no default on any branch, `dev` included: the generated
per-role passwords can't be committed to a public repo, and failing fast on a missing credential
is safer than falling back to one that could reach every service's database.
