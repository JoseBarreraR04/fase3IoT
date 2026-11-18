# Store database: PostgreSQL with this folder's schema and seed baked into the image.
# Copying them in (instead of a bind mount) means the scripts reach the Docker engine
# even when `docker compose` runs inside another container, such as aws_dev_environment
# on Docker Desktop for Windows, where the container's paths do not exist on the host.
FROM postgres:16-alpine
# PostgreSQL runs these once, in name order, the first time the data volume is empty.
COPY *.sql /docker-entrypoint-initdb.d/
