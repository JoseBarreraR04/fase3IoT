"""Tiny Redis cache used by the product lookup.

Two functions, nothing else. If Redis is down the cache simply misses and the
caller falls back to PostgreSQL: a broken cache must make the register slower,
never make it fail.
"""

import logging

import redis

from app.core.config import CACHE_TTL_SECONDS, REDIS_URL

logger = logging.getLogger(__name__)

# One client per process. redis-py keeps its own connection pool behind it.
_client = redis.Redis.from_url(REDIS_URL, decode_responses=True, socket_timeout=1)


def get(key: str) -> str | None:
    """Return the cached value, or None on a miss or if Redis is unreachable."""
    try:
        return _client.get(key)
    except redis.RedisError as error:
        logger.warning("Cache unavailable on GET %s: %s", key, error)
        return None


def set(key: str, value: str, ttl_seconds: int = CACHE_TTL_SECONDS) -> None:
    """Store a value with an expiry. Failures are logged and ignored."""
    try:
        _client.set(key, value, ex=ttl_seconds)
    except redis.RedisError as error:
        logger.warning("Cache unavailable on SET %s: %s", key, error)
