"""Pydantic 请求/响应模型。"""
from __future__ import annotations

from datetime import date, datetime

from pydantic import BaseModel, Field


class ReportIn(BaseModel):
    lab_no: str = Field(..., min_length=1, description="实验室号（非空）")
    report_no: str = Field(..., min_length=1, description="实验室内报告号（非空）")
    measured: int = Field(..., description="整数测值")


class ReportOut(ReportIn):
    id: int


class BatchReportIn(BaseModel):
    items: list[ReportIn] = Field(..., min_length=1)


class DriftConclusionOut(BaseModel):
    """漂移核算结论视图。"""

    id: int
    lab_no: str = Field(..., description="实验室号")
    calc_date: date = Field(..., description="被核算的 UTC 日期（reports.created_at 的 UTC 日）")
    status: str = Field(..., description="valid=两侧均有报告；insufficient_data=任一侧无报告")
    needs_review: bool = Field(..., description="|当日中位数-基线中位数| > 10 时为 TRUE，需排查")
    current_day_median: float | None = Field(None, description="当日全部测值中位数")
    baseline_median: float | None = Field(None, description="此前七个 UTC 日全部测值中位数")
    drift_diff: float | None = Field(None, description="当日中位数减基线中位数")
    threshold: float = Field(..., description="漂移判定阈值（10）")
    is_stale: bool = Field(..., description="结论依赖的数据事后被增改删，需重新核算")
    computed_at: datetime
    reused: bool = Field(False, description="TRUE=本次请求复用了已存在的有效/过期结论，未重新核算")
