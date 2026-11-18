# Local central database (make up-local): MySQL with the schema and seed baked into the
# image, for the same reason as db/Dockerfile: no bind mount, so it also works when
# `docker compose` runs inside aws_dev_environment. On AWS the MySQL machine gets the same
# two files through Terraform (infraestructura/compute.tf), not through this image.
FROM mysql:8.4
# MySQL runs these once, in name order, the first time the data volume is empty.
COPY *.sql /docker-entrypoint-initdb.d/
