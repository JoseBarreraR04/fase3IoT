"""Unit tests for the ingestion service.

Fase 3: the service only publishes to the queue, so these tests replace the
publisher with a fake. Validation and idempotency are the worker's job.
"""

import json

import pytest

from app.ingestion import publisher, service
from app.ingestion.tests.conftest import make_batch, make_invoice


@pytest.fixture
def published(monkeypatch):
    """Capture what the service sends to the queue."""
    messages = []
    monkeypatch.setattr(publisher, "publish_batch", messages.append)
    return messages


def test_a_batch_is_published_to_the_queue(published):
    service.receive_batch(make_batch())

    assert len(published) == 1


def test_the_message_carries_the_whole_batch(published):
    batch = make_batch(
        store_id="store-2", invoices=[make_invoice(1), make_invoice(2)]
    )

    service.receive_batch(batch)

    body = json.loads(published[0])
    assert body["store_id"] == "store-2"
    assert [i["store_invoice_id"] for i in body["invoices"]] == [1, 2]


def test_amounts_travel_as_strings_not_floats(published):
    service.receive_batch(make_batch())

    body = json.loads(published[0])
    assert body["invoices"][0]["total"] == "4000"


def test_queue_failure_is_reported(monkeypatch):
    def broken(body):
        raise publisher.QueueUnavailableError("down")

    monkeypatch.setattr(publisher, "publish_batch", broken)

    with pytest.raises(service.QueueUnavailableError):
        service.receive_batch(make_batch())
