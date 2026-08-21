from __future__ import annotations

import abc
from collections.abc import Iterable, Iterator

from ..models import FoodRecord
from ..util import log


class Source(abc.ABC):
    """A crawlable / loadable origin of food records.

    Sources must be *idempotent* and *offline-tolerant*: when the network or an
    API key is unavailable they log a warning and yield nothing rather than
    aborting the build. That is what lets the weekly CI job degrade gracefully.
    """

    key: str = "source"
    display_name: str = "Source"
    license_note: str = ""
    requires_network: bool = True

    def __init__(self, limit: int | None = None) -> None:
        self.limit = limit
        self.log = log.get(f"ifca.source.{self.key}")

    @abc.abstractmethod
    def fetch(self) -> Iterable[FoodRecord]:
        """Yield raw (un-normalized) records."""

    def run(self) -> list[FoodRecord]:
        out: list[FoodRecord] = []
        try:
            for i, rec in enumerate(self.fetch()):
                if self.limit is not None and i >= self.limit:
                    break
                rec.source = rec.source or self.key
                out.append(rec)
        except Exception as exc:  # noqa: BLE001 - sources must never kill the build
            self.log.warning("%s failed (%s); continuing with %d records",
                             self.display_name, exc, len(out))
        self.log.info("%s -> %d records", self.display_name, len(out))
        return out


def batched(items: Iterable, size: int) -> Iterator[list]:
    batch: list = []
    for it in items:
        batch.append(it)
        if len(batch) >= size:
            yield batch
            batch = []
    if batch:
        yield batch
