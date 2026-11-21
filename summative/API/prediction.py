"""Prediction and retraining API for the Rwandan food-product unit-price model.

The request schema, the price bounds and the categorical vocabulary all come from
best_model.pkl, so the API cannot drift from the notebook that trained it. The bundle
is loaded once at startup and kept in memory; no request touches the pickle.

Run it:
    uvicorn prediction:app --reload
    python prediction.py
"""

import io
import logging
import statistics
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

import joblib
import pandas as pd
import sklearn
import uvicorn
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, ConfigDict, Field, create_model
from sklearn.base import clone
from sklearn.metrics import mean_squared_error
from sklearn.model_selection import train_test_split

BASE_DIR = Path(__file__).resolve().parent
MODEL_PATH = BASE_DIR / "best_model.pkl"
RANDOM_STATE = 42
HOLDOUT_FRACTION = 0.20
PRICE_ROUNDING = 10
SURVEY_NOTE = (
    "Estimate from the 2016 to 2017 EICV5 survey patterns; it is not a live market price."
)

logger = logging.getLogger("summative.api")

# The field name served for each stored column. Anything not listed keeps its column name.
FIELD_NAMES = {"s8cq0": "product", "s8cq14": "unit", "s0q18m": "month"}


@dataclass(frozen=True)
class ModelState:
    """Everything a request needs, held in one object so /retrain can swap it atomically."""

    pipeline: Any
    metadata: dict[str, Any]
    train_frame: pd.DataFrame
    fallback_price: float

    @property
    def model_name(self) -> str:
        return str(self.metadata["model_name"])

    @property
    def target(self) -> str:
        return str(self.metadata["target"])

    @property
    def input_columns(self) -> list[str]:
        return list(self.metadata["input_columns"])

    @property
    def categorical_columns(self) -> list[str]:
        return list(self.metadata["categorical_columns"])

    @property
    def training_columns(self) -> list[str]:
        return self.input_columns + [self.target]

    def field_for(self, column: str) -> str:
        return FIELD_NAMES.get(column, column)


def median_price_lookup(metadata: dict[str, Any]) -> float:
    """Median of every product-unit median, used when a combination was never observed."""
    medians = [
        float(value)
        for by_unit in metadata["median_price_by_product_unit"].values()
        for value in by_unit.values()
    ]
    return float(statistics.median(medians))


def build_state(
    pipeline: Any, metadata: dict[str, Any], train_frame: pd.DataFrame
) -> ModelState:
    """Wrap a pipeline, its metadata and its training rows in one immutable state object."""
    frame = train_frame.loc[:, list(metadata["input_columns"]) + [metadata["target"]]].copy()
    # Plain objects, so the bundle never carries Arrow extension dtypes into a
    # deployment that does not install pyarrow.
    for column in metadata["categorical_columns"]:
        frame[column] = frame[column].astype(object)
    frame.columns = pd.Index(frame.columns.tolist(), dtype=object)
    return ModelState(
        pipeline=pipeline,
        metadata=metadata,
        train_frame=frame.reset_index(drop=True),
        fallback_price=median_price_lookup(metadata),
    )


def check_sklearn_version(metadata: dict[str, Any]) -> None:
    """Warn at startup when the installed scikit-learn differs from the pickle's."""
    saved = str(metadata.get("sklearn_version", "unknown"))
    installed = sklearn.__version__
    if saved != installed:
        logger.warning(
            "scikit-learn version mismatch: best_model.pkl was saved with %s but %s is "
            "installed; predictions and retraining may differ from training. Pin "
            "scikit-learn==%s to reproduce the notebook.",
            saved,
            installed,
            saved,
        )
    else:
        logger.info("scikit-learn %s matches best_model.pkl", installed)


def load_state() -> ModelState:
    """Load the bundle once, at startup, from the file beside this module."""
    bundle = joblib.load(MODEL_PATH)
    metadata = bundle["metadata"]
    check_sklearn_version(metadata)
    return build_state(bundle["pipeline"], metadata, bundle["train_frame"])


try:
    STATE = load_state()
except FileNotFoundError as exc:  # pragma: no cover - deployment error
    raise RuntimeError(
        f"Missing {exc.filename} beside prediction.py. "
        "Run linear_regression/multivariate.ipynb to rebuild the bundle."
    ) from exc


def _literal(values: list[str]) -> Any:
    return Literal.__getitem__(tuple(values))


def build_request_model(state: ModelState) -> type[BaseModel]:
    """One field per model input, built from the saved metadata."""
    month_range = state.metadata.get("month_range", {})
    month_min = int(month_range.get("min", 1))
    month_max = int(month_range.get("max", 12))

    fields: dict[str, Any] = {}
    for column in state.input_columns:
        name = state.field_for(column)
        if column in state.metadata["numeric_columns"]:
            fields[name] = (
                int,
                Field(
                    ...,
                    ge=month_min,
                    le=month_max,
                    description=(
                        f"{name}: interview month, an integer from {month_min} to "
                        f"{month_max}"
                    ),
                ),
            )
            continue
        allowed = list(state.metadata["allowed_values"][column])
        preview = ", ".join(repr(value) for value in allowed[:3])
        fields[name] = (
            _literal(allowed),
            Field(
                ...,
                description=(
                    f"{name}: one of the {len(allowed)} values recorded in training, "
                    f"for example {preview}; values outside the saved vocabulary are rejected"
                ),
            ),
        )
    return create_model("PredictionRequest", __config__=ConfigDict(extra="forbid"), **fields)


PredictionRequest = build_request_model(STATE)


class PredictionResponse(BaseModel):
    """The price plus the comparison a caller actually reads."""

    predicted_price_rwf: int
    unit: str
    product: str
    typical_price_rwf: float
    difference_pct: float
    note: str


app = FastAPI(
    title="Rwanda food-product unit-price API",
    version="4.0.0",
    description=(
        f"{STATE.model_name} predicting {STATE.target} (unit price in RWF), "
        "with online retraining."
    ),
)

# CORS, because the Flutter web build calls this API from the browser and the browser
# blocks cross-origin calls unless the API opts in. Allowed: GET and POST from the two
# origins listed below, carrying only a Content-Type header. Restricted: no wildcard
# origin, so random sites cannot read responses; no PUT/PATCH/DELETE; no custom
# headers; and credentials off because this API sets no cookies and has no login.
# A native Flutter build on Android or iOS is not affected by CORS at all, since CORS
# is enforced by browsers, not by the phone: the mobile app can call this API from any
# origin. Only the web build needs these entries.
ALLOWED_ORIGINS = [
    "https://linear-regression-model-ycsw.onrender.com",  # deployed API on Render
    "http://localhost:8080",  # Flutter web debug server
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type"],
    allow_credentials=False,
)


def typical_price(metadata: dict[str, Any], product: str, unit: str) -> float:
    """Median price for this product and unit from the metadata, with safe fallbacks."""
    by_unit = metadata["median_price_by_product_unit"].get(product, {})
    if unit in by_unit:
        return float(by_unit[unit])
    if by_unit:
        return float(statistics.median(float(value) for value in by_unit.values()))
    return median_price_lookup(metadata)


def predict_price(state: ModelState, payload: BaseModel) -> float:
    """One-row prediction in the saved column order, using the in-memory pipeline."""
    values = payload.model_dump()
    row = {column: values[state.field_for(column)] for column in state.input_columns}
    frame = pd.DataFrame([row], columns=state.input_columns)
    return float(state.pipeline.predict(frame)[0])


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "model": STATE.model_name,
        "training_rows": len(STATE.train_frame),
        "sklearn_version": STATE.metadata.get("sklearn_version"),
    }


@app.get("/model-info")
def model_info() -> dict[str, Any]:
    state = STATE
    return {
        "model_name": state.model_name,
        "target": state.target,
        "target_unit": state.metadata.get("target_unit"),
        "input_columns": [state.field_for(column) for column in state.input_columns],
        "month_range": state.metadata.get("month_range"),
        "price_range": state.metadata.get("price_range"),
        "allowed_value_counts": {
            state.field_for(column): len(state.metadata["allowed_values"][column])
            for column in state.categorical_columns
        },
        "training_rows": len(state.train_frame),
        "sklearn_version": state.metadata.get("sklearn_version"),
        "metrics": state.metadata.get("metrics", {}),
    }


@app.post("/predict", response_model=PredictionResponse)
def predict(payload: PredictionRequest) -> PredictionResponse:
    """Predict the unit price for one validated request."""
    state = STATE
    try:
        raw_price = predict_price(state, payload)
    except Exception as exc:  # pragma: no cover - defensive
        raise HTTPException(status_code=500, detail=f"Prediction failed: {exc}") from exc

    floor = float(state.metadata["price_range"]["min"])
    price = max(raw_price, floor)
    rounded = int(round(price / PRICE_ROUNDING) * PRICE_ROUNDING)

    typical = typical_price(state.metadata, payload.product, payload.unit)
    difference = round((rounded - typical) / typical * 100, 1) if typical else 0.0

    return PredictionResponse(
        predicted_price_rwf=rounded,
        unit=payload.unit,
        product=payload.product,
        typical_price_rwf=round(typical, 2),
        difference_pct=difference,
        note=SURVEY_NOTE,
    )


def prepare_upload(frame: pd.DataFrame, state: ModelState) -> tuple[pd.DataFrame, dict[str, Any]]:
    """Keep usable rows, count every drop reason, and report both in one object."""
    required = state.training_columns
    missing = [column for column in required if column not in frame.columns]
    if missing:
        raise HTTPException(
            status_code=422,
            detail={
                "status": "rejected",
                "reason": "the upload is missing required columns",
                "missing_columns": missing,
                "required_columns": required,
            },
        )

    work = frame.loc[:, required].copy()
    received = len(work)

    month = pd.to_numeric(work["s0q18m"], errors="coerce")
    price = pd.to_numeric(work[state.target], errors="coerce")
    unknown = pd.Series(False, index=work.index)
    for column in state.categorical_columns:
        text = work[column].astype("string").str.strip()
        work[column] = text.astype(object)
        unknown |= ~text.isin(state.metadata["allowed_values"][column])

    bad_month = month.isna() | (month < 1) | (month > 12) | (month % 1 != 0)
    bad_price = price.isna() | (price <= 0)

    dropped = {
        "unknown_category": int(unknown.sum()),
        "month_out_of_range": int((~unknown & bad_month).sum()),
        "invalid_price": int((~unknown & ~bad_month & bad_price).sum()),
    }
    keep = ~unknown & ~bad_month & ~bad_price

    cleaned = work.loc[keep].copy()
    cleaned["s0q18m"] = month.loc[keep].astype(int)
    cleaned[state.target] = price.loc[keep].astype(float)
    cleaned = cleaned.reset_index(drop=True)

    cap = float(state.metadata.get("target_cap") or cleaned[state.target].max())
    clipped = int((cleaned[state.target] > cap).sum())
    cleaned[state.target] = cleaned[state.target].clip(upper=cap)

    report = {
        "rows_received": received,
        "rows_used": len(cleaned),
        "rows_dropped": received - len(cleaned),
        "dropped": dropped,
        "rows_clipped_to_cap": clipped,
    }
    return cleaned, report


def score(state: ModelState, pipeline: Any, rows: pd.DataFrame) -> float:
    """Mean squared error of a pipeline on the given rows."""
    predictions = pipeline.predict(rows[state.input_columns])
    return float(mean_squared_error(rows[state.target], predictions))


def retrain_model(state: ModelState, rows: pd.DataFrame) -> dict[str, Any]:
    """Update the model and score the before and after states on one shared holdout."""
    combined = pd.concat(
        [state.train_frame[state.training_columns], rows], ignore_index=True
    )
    fit_rows, holdout = train_test_split(
        combined, test_size=HOLDOUT_FRACTION, random_state=RANDOM_STATE
    )
    if fit_rows.empty or holdout.empty:
        raise HTTPException(
            status_code=422,
            detail={
                "status": "rejected",
                "reason": f"at least {int(1 / HOLDOUT_FRACTION)} rows are needed to retrain",
                "training_rows": len(combined),
            },
        )

    before = score(state, state.pipeline, holdout)

    if state.model_name == "SGDRegressor":
        preprocessor = state.pipeline.named_steps["prep"]
        model = state.pipeline.named_steps["model"]
        model.partial_fit(
            preprocessor.transform(rows[state.input_columns]),
            rows[state.target].to_numpy(dtype=float),
        )
        pipeline = state.pipeline
        strategy = "partial_fit"
    else:
        pipeline = clone(state.pipeline).fit(
            fit_rows[state.input_columns], fit_rows[state.target]
        )
        strategy = "refit"

    after = score(state, pipeline, holdout)

    metadata = dict(state.metadata)
    metrics = dict(metadata.get("metrics", {}))
    metrics[state.model_name] = {
        "test_mse": round(after, 2),
        "test_rmse": round(after**0.5, 2),
        "holdout_fraction": HOLDOUT_FRACTION,
        "source": "retrain",
    }
    metadata["metrics"] = metrics

    return {
        "pipeline": pipeline,
        "metadata": metadata,
        "train_frame": combined,
        "strategy": strategy,
        "holdout_mse_before": round(before, 2),
        "holdout_mse_after": round(after, 2),
    }


def write_bundle(state: ModelState) -> bool:
    """Persist the bundle; a read-only disk on Render must not lose the in-memory model."""
    try:
        joblib.dump(
            {
                "pipeline": state.pipeline,
                "metadata": state.metadata,
                "train_frame": state.train_frame,
            },
            MODEL_PATH,
            compress=3,
        )
    except Exception as exc:  # pragma: no cover - deployment error
        logger.warning(
            "could not write %s (%s); the retrained model stays in memory only",
            MODEL_PATH,
            exc,
        )
        return False
    return True


@app.post("/retrain")
async def retrain(file: UploadFile = File(...)) -> dict[str, Any]:
    """Retrain from a CSV of the five inputs plus the saved target column."""
    global STATE

    contents = await file.read()
    if not contents:
        raise HTTPException(status_code=422, detail="The uploaded file is empty.")

    try:
        uploaded = pd.read_csv(io.BytesIO(contents))
    except Exception as exc:
        raise HTTPException(status_code=422, detail=f"Could not parse the CSV: {exc}") from exc

    state = STATE
    prepared, report = prepare_upload(uploaded, state)
    if prepared.empty:
        raise HTTPException(
            status_code=422,
            detail={"status": "rejected", "reason": "no usable rows after cleaning", **report},
        )

    outcome = retrain_model(state, prepared)
    new_state = build_state(
        outcome["pipeline"], outcome["metadata"], outcome["train_frame"]
    )
    STATE = new_state
    saved = write_bundle(new_state)

    return {
        "status": "retrained",
        "strategy": outcome["strategy"],
        "model_name": new_state.model_name,
        "rows_used": report["rows_used"],
        "rows_dropped": report["rows_dropped"],
        "training_rows": len(new_state.train_frame),
        "holdout_mse_before": outcome["holdout_mse_before"],
        "holdout_mse_after": outcome["holdout_mse_after"],
        "saved_to_disk": saved,
        **report,
    }


if __name__ == "__main__":
    uvicorn.run("prediction:app", host="127.0.0.1", port=8000)
