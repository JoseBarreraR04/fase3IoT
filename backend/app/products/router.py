"""HTTP surface for the product catalog.

This layer only translates between HTTP and the service layer: it parses the
request, calls a service, and maps domain exceptions onto status codes. It
builds no queries.

Fase 3: the EAN lookup is cached in Redis (cache-aside). Only the lookup the
register uses while scanning is cached; the payment flow still re-reads prices
from PostgreSQL, because money is never taken from a cache.
"""

import logging

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.core import cache
from app.core.database import get_session
from app.products import service
from app.products.schemas import ProductResponse

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/products", tags=["products"])


@router.get("/{ean}", response_model=ProductResponse)
def get_product(
    ean: str,
    session: Session = Depends(get_session),
) -> ProductResponse:
    key = f"product:{ean}"

    # 1. Try the cache first.
    cached = cache.get(key)
    if cached is not None:
        logger.info("Cache HIT %s", key)
        return ProductResponse.model_validate_json(cached)

    # 2. Miss: go to the database, exactly as before.
    logger.info("Cache MISS %s", key)
    try:
        product = service.get_product(session, ean)
    except service.ProductNotFoundError as error:
        # Unknown EANs are not cached, so a product added later shows up at once.
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail=str(error)
        ) from error

    # 3. Keep the answer for next time.
    response = ProductResponse.model_validate(product)
    cache.set(key, response.model_dump_json())
    return response
