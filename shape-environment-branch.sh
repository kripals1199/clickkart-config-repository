#!/usr/bin/env bash
#
# Shapes a config branch for a non-dev environment, starting from dev's content.
#
#   usage: ./shape-environment-branch.sh test|qa|prod
#
# Reconstructed, not recovered. The original test/qa/prod branches were lost when this repository
# was replaced; what follows are the conventions those branches actually used, observed while
# working on them. Anything not covered here is inherited from dev unchanged and should be
# reviewed - inheriting a dev value is the safe-looking failure, not a safe one.
set -euo pipefail

ENV="${1:?usage: shape-environment-branch.sh test|qa|prod}"
case "$ENV" in test|qa|prod) ;; *) echo "unknown environment: $ENV" >&2; exit 1 ;; esac

# ---------------------------------------------------------------------------------------------
# 1. Secrets must not fall back to a development placeholder.
#
# Every one of these carries a ${VAR:dev-only-...} or ${VAR:root} default on dev, which is right
# there: a laptop should start without a vault. Anywhere else it is the worst kind of default -
# the service starts, looks healthy, and is signing tokens or authenticating callers with a value
# published in a git repository. Stripping the default turns that into a refusal to start.
# ---------------------------------------------------------------------------------------------
for f in *.properties; do
  sed -i -E 's|=\$\{([A-Z_]+):dev-only[^}]*\}|=${\1}|g' "$f"
  sed -i -E 's|(spring\.datasource\.password=)\$\{DB_PASSWORD:root\}|\1${DB_PASSWORD}|' "$f"
  # The Eureka URL embeds its password inline rather than as a standalone property.
  sed -i -E 's|\$\{EUREKA_DASHBOARD_PASSWORD:dev-only[^}]*\}|${EUREKA_DASHBOARD_PASSWORD}|g' "$f"
done

# ---------------------------------------------------------------------------------------------
# 2. Topology.
#
# test and qa name their hosts after the environment. prod deliberately has no fallback at all:
# a production topology guessed from a default is a production topology nobody chose.
# ---------------------------------------------------------------------------------------------
if [ "$ENV" = "prod" ]; then
  for f in *.properties; do
    sed -i -E 's|\$\{([A-Z_]*HOSTNAME):localhost\}|${\1}|g' "$f"
    sed -i -E 's|\$\{EUREKA_SERVER_HOST:localhost\}|${EUREKA_SERVER_HOST}|g' "$f"
    sed -i -E 's|\$\{DB_HOST:localhost\}|${DB_HOST}|g' "$f"
    sed -i -E 's|\$\{REVOCATION_REDIS_HOST:(localhost\|127\.0\.0\.1)\}|${REVOCATION_REDIS_HOST}|g' "$f"
  done
else
  for f in *.properties; do
    sed -i -E "s|\\\$\{([A-Z_]*)_SERVICE_HOSTNAME:localhost\}|\${\1_SERVICE_HOSTNAME:\L\1\E-service-$ENV}|g" "$f"
    sed -i -E "s|\\\$\{GATEWAY_HOSTNAME:localhost\}|\${GATEWAY_HOSTNAME:gateway-$ENV}|g" "$f"
    sed -i -E "s|\\\$\{EUREKA_SERVER_HOST:localhost\}|\${EUREKA_SERVER_HOST:eureka-server-$ENV}|g" "$f"
    sed -i -E "s|\\\$\{DB_HOST:localhost\}|\${DB_HOST:postgres-$ENV}|g" "$f"
    sed -i -E "s|\\\$\{REVOCATION_REDIS_HOST:(localhost\|127\.0\.0\.1)\}|\${REVOCATION_REDIS_HOST:redis-$ENV}|g" "$f"
  done
fi

# ---------------------------------------------------------------------------------------------
# 2b. CORS must not fall back to a developer's browser.
#
# allowed-origins defaults to http://localhost:4200 everywhere, which is right on dev. Anywhere
# else an unset ALLOWED_ORIGINS leaves the service accepting credentialed cross-origin requests
# from a laptop. The config already describes this as a "safe localhost default for dev only" -
# this is what makes that sentence true rather than aspirational.
# ---------------------------------------------------------------------------------------------
for f in *.properties; do
  sed -i -E 's|=\$\{ALLOWED_ORIGINS:http://localhost:4200\}|=${ALLOWED_ORIGINS}|g' "$f"
done

# ---------------------------------------------------------------------------------------------
# 3. Environment-specific behaviour that is not just a hostname.
# ---------------------------------------------------------------------------------------------
if [ "$ENV" = "prod" ]; then
  # Prod provisions a real mail server, so the health indicator is the only automated signal that
  # outbound delivery has broken. It is not in the readiness group, so a mail outage reports DOWN
  # without pulling the pod from the Service.
  sed -i 's|management.health.mail.enabled=${MAIL_HEALTH_ENABLED:false}|management.health.mail.enabled=${MAIL_HEALTH_ENABLED:true}|' clickkart-user-service.properties
  # Debug SQL logging is a data-leak surface in production, not a convenience.
  sed -i -E 's|^(logging\.level\.com\.clickkart)=DEBUG$|\1=INFO|' *.properties
  sed -i -E 's|^(sql\.log-level)=DEBUG$|\1=WARN|' *.properties
fi

echo "shaped for $ENV:"
echo "  secrets still carrying a dev default : $(grep -rcE '=\$\{[A-Z_]+:(dev-only[^}]*|root)\}' *.properties | awk -F: '{s+=$2} END {print s+0}')"
echo "  hosts still defaulting to localhost  : $(grep -rc 'localhost' *.properties | awk -F: '{s+=$2} END {print s+0}')"
