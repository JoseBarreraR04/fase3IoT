"""HTTP client for the central site's ingestion API.

Kept apart from the service so the batching rule can be unit tested with this
module replaced by a stub, without any HTTP happening.
"""

import logging
from typing import Any

import httpx

from app.core.config import CENTRAL_API_TIMEOUT_SECONDS, CENTRAL_API_URL

logger = logging.getLogger(__name__)


class CentralSiteUnavailableError(Exception):
    """Head office could not be reached, or refused the batch.

    Raised for both cases on purpose: from the forwarder's point of view the
    only thing that matters is that the batch was NOT confirmed, so nothing
    may be stamped and everything must be retried.
    """


def send_batch(payload: dict[str, Any]) -> dict[str, Any]:
    """Ship one batch and return head office's acknowledgement.

    Fase 3: head office answers 202 {"status": "received", ...} once the batch
    is queued in RabbitMQ. Any 2xx means the whole batch is delivered.
    """
    try:
        response = httpx.post(
            f"{CENTRAL_API_URL}/sales/batch",
            json=payload,
            timeout=CENTRAL_API_TIMEOUT_SECONDS,
        )
        response.raise_for_status()
        return response.json()
    except (httpx.HTTPError, ValueError) as error:
        raise CentralSiteUnavailableError(str(error)) from error
