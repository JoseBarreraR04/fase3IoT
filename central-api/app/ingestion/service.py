"""Ingestion business logic.

Fase 3: this layer no longer writes to MySQL. Receiving a batch means putting
it on the RabbitMQ queue; the `central-worker` service validates it and
inserts it into the database.

This layer knows nothing about HTTP: it takes plain values and raises plain
exceptions, which is what makes it unit testable without starting a server.
"""

import logging

from app.ingestion import publisher
from app.ingestion.publisher import QueueUnavailableError
from app.ingestion.schemas import BatchRequest

logger = logging.getLogger(__name__)

__all__ = ["QueueUnavailableError", "receive_batch"]


def receive_batch(batch: BatchRequest) -> None:
    """Publish a batch to the ingestion queue.

    Raises QueueUnavailableError when RabbitMQ does not confirm the message,
    so the caller can tell the store to retry later.
    """
    publisher.publish_batch(batch.model_dump_json())

    logger.info(
        "Batch from %s queued: %s invoices", batch.store_id, len(batch.invoices)
    )
