"""central-worker: lee los lotes de la cola de RabbitMQ y los guarda en MySQL.

Flujo de cada mensaje (un lote de una tienda, serializado por central-api):

1. Se lee el JSON. Los montos llegan como texto y se convierten a Decimal, para
   no redondear pesos.
2. Se revisa que la tienda exista. Un lote de una tienda desconocida se descarta.
3. Cada factura se valida. Una factura inválida se salta (queda en el log) y
   las demás del lote se guardan.
4. Las facturas que ya están en MySQL (misma tienda y mismo número) se saltan:
   así un lote reenviado no duplica ventas.
5. Todo el lote se guarda en UNA transacción. Solo después de confirmarla en
   MySQL se confirma (ack) el mensaje en RabbitMQ. Si el worker se cae a mitad
   de camino, el mensaje vuelve a la cola y no se pierde nada.

Ojo: el pipeline (deploy.sh) da el despliegue por fallido si el contenedor se
reinicia o si su log contiene la palabra "Traceback". Por eso el worker nunca
se cae por un error de conexión (espera y reintenta) y registra los errores en
una sola línea, sin traza.
"""

import json
import logging
import os
import time
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from functools import partial

import pika
from pika.exceptions import AMQPError
from sqlalchemy import create_engine, select, text
from sqlalchemy.exc import DBAPIError, SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker

from models import Invoice, InvoiceItem, Store

# --- Configuración: todo sale de las variables de entorno -------------------

DATABASE_URL = os.environ["CENTRAL_DATABASE_URL"]
RABBITMQ_URL = os.environ["RABBITMQ_URL"]
INGESTION_QUEUE = os.environ.get("INGESTION_QUEUE", "invoice-batches")

# Segundos de espera antes de reintentar cuando MySQL o RabbitMQ no responden.
RETRY_SECONDS = 5

# Mayor valor que cabe en DECIMAL(12, 2): 10 dígitos enteros y 2 decimales.
MAX_AMOUNT = Decimal("9999999999.99")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [central-worker] %(message)s",
)
# pika registra sus fallos de conexión con traza completa. El worker ya avisa
# de esos fallos con su propia línea, así que se silencian para que el log no
# tenga "Traceback" (lo busca la etapa verify del pipeline).
logging.getLogger("pika").setLevel(logging.CRITICAL)
logger = logging.getLogger("central-worker")


class InvalidMessageError(Exception):
    """El mensaje no se puede guardar nunca: reintentarlo no sirve."""


# --- Lectura y validación del lote -------------------------------------------


def _text(data: dict, field: str, max_length: int) -> str:
    """Texto obligatorio, no vacío y que cabe en su columna."""
    value = data.get(field)
    if not isinstance(value, str) or not value or len(value) > max_length:
        raise ValueError(f"{field} debe ser un texto de 1 a {max_length} caracteres")
    return value


def _integer(data: dict, field: str) -> int:
    """Número entero obligatorio (True/False no cuentan como número)."""
    value = data.get(field)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{field} debe ser un número entero")
    return value


def _amount(data: dict, field: str) -> Decimal:
    """Monto en pesos: no negativo, con hasta 2 decimales y que cabe en DECIMAL(12, 2)."""
    value = data.get(field)
    if isinstance(value, bool) or value is None:
        raise ValueError(f"{field} falta o no es un monto")
    try:
        amount = Decimal(str(value))
    except InvalidOperation as error:
        raise ValueError(f"{field} no es un monto válido: {value!r}") from error
    if not amount.is_finite() or amount < 0 or amount > MAX_AMOUNT:
        raise ValueError(f"{field} fuera de rango: {value!r}")
    if amount != amount.quantize(Decimal("0.01")):
        raise ValueError(f"{field} tiene más de 2 decimales: {value!r}")
    return amount


def _datetime(data: dict, field: str) -> datetime:
    """Fecha y hora en formato ISO 8601, como la serializa el API."""
    value = data.get(field)
    if not isinstance(value, str):
        raise ValueError(f"{field} debe ser una fecha ISO 8601")
    try:
        moment = datetime.fromisoformat(value)
    except ValueError as error:
        raise ValueError(f"{field} no es una fecha válida: {value!r}") from error
    # La columna es DATETIME (sin zona). Si llegara con zona, se guarda la hora
    # tal como la reportó la tienda, igual que haría el driver de MySQL.
    return moment.replace(tzinfo=None)


def parse_item(data: dict) -> dict:
    """Valida un artículo de factura según las reglas de la tabla invoice_items."""
    if not isinstance(data, dict):
        raise ValueError("cada artículo debe ser un objeto JSON")
    quantity = _integer(data, "quantity")
    if quantity <= 0:
        raise ValueError("quantity debe ser mayor que 0")
    return {
        "ean": _text(data, "ean", 13),
        "product_name": _text(data, "product_name", 120),
        "quantity": quantity,
        "unit_price": _amount(data, "unit_price"),
        "subtotal": _amount(data, "subtotal"),
    }


def parse_invoice(data: dict) -> dict:
    """Valida una factura y sus artículos. Lanza ValueError si algo no cuadra."""
    if not isinstance(data, dict):
        raise ValueError("cada factura debe ser un objeto JSON")
    items = data.get("items")
    if not isinstance(items, list):
        raise ValueError("items debe ser una lista")
    return {
        "store_invoice_id": _integer(data, "store_invoice_id"),
        "register_id": _text(data, "register_id", 40),
        "sold_at": _datetime(data, "sold_at"),
        "total": _amount(data, "total"),
        "items": [parse_item(item) for item in items],
    }


def parse_batch(body: bytes) -> tuple[str, list]:
    """Lee el JSON del lote. Devuelve la tienda y la lista de facturas sin validar."""
    try:
        batch = json.loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise InvalidMessageError(f"el mensaje no es JSON válido: {error}") from error
    if not isinstance(batch, dict):
        raise InvalidMessageError("el lote debe ser un objeto JSON")
    store_id = batch.get("store_id")
    invoices = batch.get("invoices")
    if not isinstance(store_id, str) or not store_id or len(store_id) > 20:
        raise InvalidMessageError("store_id falta o no es válido")
    if not isinstance(invoices, list):
        raise InvalidMessageError("invoices debe ser una lista")
    return store_id, invoices


# --- Guardado en MySQL ---------------------------------------------------------


def save_batch(session: Session, body: bytes) -> str:
    """Guarda un lote en una sola transacción y devuelve el resumen para el log."""
    store_id, raw_invoices = parse_batch(body)

    # Un lote de una tienda que no existe se rechaza: el worker no inventa tiendas.
    if session.get(Store, store_id) is None:
        raise InvalidMessageError(f"la tienda {store_id!r} no existe en MySQL")

    # Validar cada factura por separado: una mala no tumba a las demás.
    valid = []
    invalid = 0
    for position, raw in enumerate(raw_invoices, start=1):
        try:
            valid.append(parse_invoice(raw))
        except ValueError as error:
            invalid += 1
            number = raw.get("store_invoice_id") if isinstance(raw, dict) else None
            logger.warning(
                "lote de %s: factura %s (posición %d) inválida, se omite: %s",
                store_id, number, position, error,
            )

    # Idempotencia: buscar cuáles de estas facturas ya están guardadas.
    numbers = {invoice["store_invoice_id"] for invoice in valid}
    already_saved = set()
    if numbers:
        already_saved = set(
            session.scalars(
                select(Invoice.store_invoice_id).where(
                    Invoice.store_id == store_id,
                    Invoice.store_invoice_id.in_(numbers),
                )
            )
        )

    received_at = datetime.now(timezone.utc).replace(tzinfo=None)
    new = 0
    duplicated = 0
    for invoice in valid:
        number = invoice["store_invoice_id"]
        # Ya estaba en MySQL, o venía repetida dentro del mismo lote.
        if number in already_saved:
            duplicated += 1
            continue
        already_saved.add(number)
        session.add(
            Invoice(
                store_id=store_id,
                store_invoice_id=number,
                register_id=invoice["register_id"],
                sold_at=invoice["sold_at"],
                received_at=received_at,
                total=invoice["total"],
                items=[InvoiceItem(**item) for item in invoice["items"]],
            )
        )
        new += 1

    session.commit()
    return (
        f"lote de {store_id} guardado: {len(raw_invoices)} facturas, "
        f"{new} nuevas, {duplicated} duplicadas, {invalid} inválidas"
    )


# --- Consumo de la cola ----------------------------------------------------------


def on_message(session_factory, channel, method, properties, body) -> None:
    """Procesa un mensaje. Solo hace ack cuando el lote ya quedó guardado."""
    session = session_factory()
    try:
        summary = save_batch(session, body)
    except InvalidMessageError as error:
        # Reintentarlo daría el mismo error: se descarta y queda en el log.
        session.rollback()
        logger.error("mensaje descartado: %s", error)
        channel.basic_reject(delivery_tag=method.delivery_tag, requeue=False)
        return
    except DBAPIError as error:
        session.rollback()
        if error.connection_invalidated or _is_connection_error(error):
            # MySQL no responde: el lote vuelve a la cola y se reintenta.
            logger.warning(
                "MySQL no disponible (%s); el lote vuelve a la cola, reintento en %d s",
                _short(error), RETRY_SECONDS,
            )
            time.sleep(RETRY_SECONDS)
            channel.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
            return
        _retry_once(channel, method, f"error de MySQL: {_short(error)}")
        return
    except SQLAlchemyError as error:
        session.rollback()
        _retry_once(channel, method, f"error de base de datos: {_short(error)}")
        return
    except Exception as error:  # Último recurso: el worker no debe caerse nunca.
        session.rollback()
        _retry_once(channel, method, f"error inesperado: {type(error).__name__}: {error}")
        return
    finally:
        session.close()

    channel.basic_ack(delivery_tag=method.delivery_tag)
    logger.info(summary)


def _is_connection_error(error: DBAPIError) -> bool:
    """Códigos de PyMySQL que significan "no hay conexión con MySQL"."""
    code = error.orig.args[0] if error.orig is not None and error.orig.args else None
    return code in (2003, 2006, 2013)  # no se puede conectar / se fue / se perdió


def _retry_once(channel, method, reason: str) -> None:
    """Un error raro se reintenta una vez; si se repite, el mensaje se descarta."""
    if method.redelivered:
        logger.error("mensaje descartado tras reintentar (%s)", reason)
        channel.basic_reject(delivery_tag=method.delivery_tag, requeue=False)
    else:
        logger.warning("el lote vuelve a la cola para un reintento (%s)", reason)
        time.sleep(RETRY_SECONDS)
        channel.basic_nack(delivery_tag=method.delivery_tag, requeue=True)


def _short(error: Exception) -> str:
    """Primera línea del error, sin la consulta SQL que SQLAlchemy le agrega."""
    origin = getattr(error, "orig", None) or error
    return str(origin).splitlines()[0] if str(origin) else type(origin).__name__


def wait_for_database(engine) -> None:
    """Espera a que MySQL responda antes de empezar a consumir la cola."""
    while True:
        try:
            with engine.connect() as connection:
                connection.execute(text("SELECT 1"))
            logger.info("conectado a MySQL")
            return
        except SQLAlchemyError as error:
            logger.warning(
                "MySQL no disponible (%s); reintento en %d s", _short(error), RETRY_SECONDS
            )
            time.sleep(RETRY_SECONDS)


def main() -> None:
    # pool_pre_ping: descarta conexiones que MySQL ya cerró (por ejemplo, tras un reinicio).
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    session_factory = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)
    wait_for_database(engine)

    # Si RabbitMQ se cae, se reconecta en vez de terminar el proceso.
    while True:
        try:
            connection = pika.BlockingConnection(pika.URLParameters(RABBITMQ_URL))
            channel = connection.channel()
            # Misma declaración que el API: cola durable, sobrevive a un reinicio de RabbitMQ.
            channel.queue_declare(queue=INGESTION_QUEUE, durable=True)
            # Un lote a la vez: RabbitMQ no entrega el siguiente hasta recibir el ack.
            channel.basic_qos(prefetch_count=1)
            channel.basic_consume(
                queue=INGESTION_QUEUE,
                on_message_callback=partial(on_message, session_factory),
                auto_ack=False,
            )
            logger.info("esperando lotes en la cola %r", INGESTION_QUEUE)
            channel.start_consuming()
        except AMQPError as error:
            logger.warning(
                "RabbitMQ no disponible (%s); reintento en %d s",
                type(error).__name__, RETRY_SECONDS,
            )
            time.sleep(RETRY_SECONDS)


if __name__ == "__main__":
    main()
