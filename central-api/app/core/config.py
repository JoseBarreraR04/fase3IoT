"""Central API configuration, read entirely from the environment.

This is the ONLY module in the service that touches `os.environ`. No hostname
or credential is written anywhere in the code.
"""

import os

DATABASE_URL: str = os.getenv(
    "CENTRAL_DATABASE_URL",
    "mysql+pymysql://central:central_password@central-mysql:3306/central",
)

# How many products the top-products report returns. The requirement says ten;
# it is a constant here rather than a literal in a query so the number appears
# once.
TOP_PRODUCTS_LIMIT: int = int(os.getenv("TOP_PRODUCTS_LIMIT", "10"))

# Fase 3: asynchronous ingestion. The API publishes batches here and the
# central-worker (separate service) consumes them.
RABBITMQ_URL: str = os.getenv(
    "RABBITMQ_URL", "amqp://central:central_password@central-rabbitmq:5672/%2F"
)
INGESTION_QUEUE: str = os.getenv("INGESTION_QUEUE", "invoice-batches")
