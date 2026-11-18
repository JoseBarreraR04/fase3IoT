"""Helpers to build batches for the ingestion tests."""

from datetime import datetime
from decimal import Decimal

from app.ingestion.schemas import BatchRequest, InvoiceRequest, InvoiceItemRequest


def make_item(ean="7702001010301", name="Arroz", quantity=2, unit_price="2000"):
    price = Decimal(unit_price)
    return InvoiceItemRequest(
        ean=ean,
        product_name=name,
        quantity=quantity,
        unit_price=price,
        subtotal=price * quantity,
    )


def make_invoice(store_invoice_id=1, items=None, register_id="register-1"):
    items = items if items is not None else [make_item()]
    return InvoiceRequest(
        store_invoice_id=store_invoice_id,
        register_id=register_id,
        sold_at=datetime(2026, 8, 26, 12, 0, 0),
        total=sum(item.subtotal for item in items),
        items=items,
    )


def make_batch(store_id="store-1", invoices=None):
    return BatchRequest(
        store_id=store_id,
        invoices=invoices if invoices is not None else [make_invoice()],
    )
