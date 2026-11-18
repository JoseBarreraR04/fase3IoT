"""HTTP surface for batch ingestion.

Fase 3: this endpoint no longer touches MySQL. It only checks the request
shape (Pydantic does that), drops the batch on a RabbitMQ queue and answers
"received". The `central-worker` service does the validation and
the inserts that used to happen here.
"""

from fastapi import APIRouter, HTTPException, status

from app.ingestion import service
from app.ingestion.schemas import BatchReceivedResponse, BatchRequest

router = APIRouter(prefix="/sales", tags=["ingestion"])


@router.post(
    "/batch",
    response_model=BatchReceivedResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
def ingest_batch(batch: BatchRequest) -> BatchReceivedResponse:
    try:
        service.receive_batch(batch)
    except service.QueueUnavailableError as error:
        # Not confirmed: the forwarder stamps nothing and retries later.
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Ingestion queue unavailable, retry later",
        ) from error

    return BatchReceivedResponse(
        store_id=batch.store_id,
        invoice_count=len(batch.invoices),
    )
