"""统一 JSON 响应：支持 UUID/datetime 序列化。"""
from __future__ import annotations

import json
import uuid
from datetime import datetime

from fastapi.responses import JSONResponse


class _Encoder(json.JSONEncoder):
    def default(self, o):
        if isinstance(o, uuid.UUID):
            return str(o)
        if isinstance(o, datetime):
            return o.isoformat()
        return super().default(o)


class AppJSONResponse(JSONResponse):
    def render(self, content) -> bytes:
        return json.dumps(content, ensure_ascii=False, cls=_Encoder).encode("utf-8")
