"""Batch API input and output models.

Amounts arrive as strings and are parsed into Decimal. Accepting a JSON float
would round Colombian pesos on the way in, which is not a rounding a reporting
system may do quietly.
"""

from datetime import datetime
from decimal import Decimal

from pydantic import BaseModel, Field


class InvoiceItemRequest(BaseModel):
    ean: str = Field(min_length=1, max_length=13)
    product_name: str = Field(min_length=1, max_length=120)
    quantity: int
    unit_price: Decimal
    subtotal: Decimal


class InvoiceRequest(BaseModel):
    """One invoice as its store sends it."""

    # The invoice's identifier in its own store. Paired with the batch's
    # store_id, this is what makes ingestion idempotent.
    store_invoice_id: int
    register_id: str = Field(min_length=1, max_length=40)
    sold_at: datetime
    total: Decimal
    items: list[InvoiceItemRequest]


class BatchRequest(BaseModel):
    """One batch from one store.

    The store travels here rather than on each invoice: a batch comes from
    exactly one store, and repeating it per invoice would invite the two to
    disagree.
    """

    store_id: str = Field(min_length=1, max_length=20)
    invoices: list[InvoiceRequest]


class BatchReceivedResponse(BaseModel):
    """Fase 3: head office only confirms the batch is safely queued.

    It no longer says which invoices were new and which were duplicates: that
    is decided later, by the worker, when it writes to MySQL. "Received" means
    "RabbitMQ holds it durably", which is enough for the forwarder to stamp
    every invoice it sent.
    """

    status: str = "received"
    store_id: str
    invoice_count: int
