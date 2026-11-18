"""Publishes ingestion batches to RabbitMQ.

Deliberately simple: one short-lived connection per batch. A store sends at
most one batch every few seconds, so the cost of connecting is irrelevant and
there is no connection state to get wrong.
"""

import pika
from pika.exceptions import AMQPError

from app.core.config import INGESTION_QUEUE, RABBITMQ_URL


class QueueUnavailableError(Exception):
    """RabbitMQ could not be reached or did not confirm the message."""


def publish_batch(body: str) -> None:
    """Put one batch on the queue, durably, or raise QueueUnavailableError."""
    try:
        connection = pika.BlockingConnection(pika.URLParameters(RABBITMQ_URL))
        try:
            channel = connection.channel()

            # durable=True: the queue survives a RabbitMQ restart.
            channel.queue_declare(queue=INGESTION_QUEUE, durable=True)

            # Publisher confirms: basic_publish only returns once RabbitMQ has
            # taken responsibility for the message. Without this, "received"
            # could be a lie.
            channel.confirm_delivery()

            channel.basic_publish(
                exchange="",
                routing_key=INGESTION_QUEUE,
                body=body,
                properties=pika.BasicProperties(
                    content_type="application/json",
                    delivery_mode=2,  # persistent: written to disk
                ),
                mandatory=True,
            )
        finally:
            connection.close()
    except AMQPError as error:
        raise QueueUnavailableError(str(error)) from error
