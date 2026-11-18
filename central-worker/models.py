"""Modelos ORM de las tablas de MySQL que usa el worker.

El worker es un servicio independiente: no importa nada de central-api. Por
eso repite aquí las tablas de central-db/01-schema.sql. Cada atributo se llama
igual que su columna.

El esquema NO se crea desde estos modelos: lo crean los scripts SQL de
central-db/ al primer arranque de MySQL. Estos modelos solo lo reflejan.
"""

from datetime import datetime
from decimal import Decimal

from sqlalchemy import (
    DateTime,
    ForeignKey,
    Integer,
    Numeric,
    String,
    UniqueConstraint,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    """Base común de los modelos del worker."""


class Store(Base):
    """Una tienda de la cadena. Se siembra en 02-seed.sql; el worker solo la lee."""

    __tablename__ = "stores"

    id: Mapped[str] = mapped_column(String(20), primary_key=True)
    name: Mapped[str] = mapped_column(String(80), nullable=False)


class Invoice(Base):
    """Una factura consolidada: una compra terminada en una tienda."""

    __tablename__ = "invoices"
    __table_args__ = (
        # La garantía de idempotencia: el número de factura solo es único
        # dentro de su tienda (las dos tiendas numeran desde 1).
        UniqueConstraint(
            "store_id", "store_invoice_id", name="uq_invoices_store_invoice"
        ),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    store_id: Mapped[str] = mapped_column(
        String(20), ForeignKey("stores.id"), nullable=False
    )
    store_invoice_id: Mapped[int] = mapped_column(Integer, nullable=False)
    register_id: Mapped[str] = mapped_column(String(40), nullable=False)
    # Cuándo ocurrió la venta, según la tienda.
    sold_at: Mapped[datetime] = mapped_column(DateTime, nullable=False)
    # Cuándo la guardó la sede central (la escribe el worker).
    received_at: Mapped[datetime] = mapped_column(DateTime, nullable=False)
    total: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)

    items: Mapped[list["InvoiceItem"]] = relationship(
        back_populates="invoice",
        cascade="all, delete-orphan",
    )


class InvoiceItem(Base):
    """Una línea de una factura: un producto vendido."""

    __tablename__ = "invoice_items"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    invoice_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("invoices.id", ondelete="CASCADE"), nullable=False
    )
    ean: Mapped[str] = mapped_column(String(13), nullable=False)
    # Desnormalizado a propósito: la sede no tiene catálogo de productos.
    product_name: Mapped[str] = mapped_column(String(120), nullable=False)
    quantity: Mapped[int] = mapped_column(Integer, nullable=False)
    unit_price: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    subtotal: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)

    invoice: Mapped["Invoice"] = relationship(back_populates="items")
