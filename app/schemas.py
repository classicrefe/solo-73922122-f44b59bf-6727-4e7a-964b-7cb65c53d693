"""Pydantic 请求/响应模型。"""
from __future__ import annotations

from pydantic import BaseModel, Field


class ReportIn(BaseModel):
    lab_no: str = Field(..., min_length=1, description="实验室号（非空）")
    report_no: str = Field(..., min_length=1, description="实验室内报告号（非空）")
    measured: int = Field(..., description="整数测值")


class ReportOut(ReportIn):
    id: int


class BatchReportIn(BaseModel):
    items: list[ReportIn] = Field(..., min_length=1)
