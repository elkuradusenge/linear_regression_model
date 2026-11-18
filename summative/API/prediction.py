"""Prediction and retraining API for the Rwandan food-product quantity model.

The feature contract, the numeric bounds and the categorical vocabulary all come
from the artifacts stored beside this file, so they are defined in one place.

Run it:
    uvicorn prediction:app --reload
    python prediction.py
"""

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

import joblib
import pandas as pd
import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, ConfigDict, Field, create_model

BASE_DIR = Path(__file__).resolve().parent
MODEL_PATH = BASE_DIR / "best_model.pkl"
TRAINING_DATA_PATH = BASE_DIR / "training_data.csv.gz"
RANDOM_STATE = 42
HOLDOUT_FRACTION = 0.20
BOUND_MARGIN = 0.10


@dataclass
class ModelState:
    """Everything the routes need, held in one object so /retrain can swap it."""

    pipeline: Any
    metadata: dict[str, Any]
    training_frame: pd.DataFrame
    bounds: dict[str, tuple[float, float]]
    integral_columns: set[str]

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
    def numeric_columns(self) -> list[str]:
        return list(self.metadata["numeric_columns"])

    @property
    def categorical_columns(self) -> list[str]:
        return list(self.metadata["categorical_columns"])

    @property
    def training_columns(self) -> list[str]:
        return self.input_columns + [self.target]


def compute_bounds(
    frame: pd.DataFrame,
    numeric_columns: list[str],
    integral_columns: set[str],
) -> dict[str, tuple[float, float]]:
    """Acceptable range per numeric column.

    Continuous columns use the 0.1th-99.9th percentile plus a 10% margin.
    Integer columns use their observed range, so month stays 1-12.
    """
    bounds: dict[str, tuple[float, float]] = {}
    for column in numeric_columns:
        values = pd.to_numeric(frame[column], errors="coerce").dropna()
        if values.empty:
            bounds[column] = (0.0, 1.0)
            continue
        if column in integral_columns:
            bounds[column] = (float(values.min()), float(values.max()))
            continue
        low = float(values.quantile(0.001))
        high = float(values.quantile(0.999))
        margin = max((high - low) * BOUND_MARGIN, 1e-6)
        bounds[column] = (max(0.0, low - margin), high + margin)
    return bounds


def load_state() -> ModelState:
    """Load the bundle and its training data once, at startup."""
    bundle = joblib.load(MODEL_PATH)
    metadata = bundle["metadata"]
    categorical = list(metadata["categorical_columns"])

    # Categoricals must be read as text, or codes such as "01" come back as 1.
    frame = pd.read_csv(
        TRAINING_DATA_PATH, dtype={column: "string" for column in categorical}
    )
    for column in categorical:
        frame[column] = frame[column].str.strip()
        unexpected = set(frame[column].dropna()) - set(metadata["allowed_values"][column])
        if unexpected:
            raise RuntimeError(
                f"{TRAINING_DATA_PATH.name} holds {column} values the bundle never saw: "
                f"{sorted(unexpected)[:5]}. Regenerate the training export."
            )

    integral = {
        column
        for column in metadata["numeric_columns"]
        if pd.api.types.is_integer_dtype(frame[column])
    }
    return ModelState(
        pipeline=bundle["pipeline"],
        metadata=metadata,
        training_frame=frame,
        bounds=compute_bounds(frame, metadata["numeric_columns"], integral),
        integral_columns=integral,
    )


try:
    STATE = load_state()
except FileNotFoundError as exc:  # pragma: no cover - deployment error
    raise RuntimeError(
        f"Missing {exc.filename} beside prediction.py. "
        "Run linear_regression/multivariate.ipynb and rebuild the training export."
    ) from exc


def _literal(values: list[str]) -> Any:
    return Literal.__getitem__(tuple(values))


def build_request_model(state: ModelState) -> type[BaseModel]:
    """One field per model input, built from the stored metadata."""
    fields: dict[str, Any] = {}
    for column in state.input_columns:
        if column in state.numeric_columns:
            low, high = state.bounds[column]
            if column in state.integral_columns:
                fields[column] = (
                    int,
                    Field(
                        ...,
                        ge=int(low),
                        le=int(high),
                        description=f"{column}: integer, observed training range {int(low)}-{int(high)}",
                    ),
                )
            else:
                fields[column] = (
                    float,
                    Field(
                        ...,
                        ge=low,
                        le=high,
                        description=(
                            f"{column}: number in [{low:.4g}, {high:.4g}] "
                            f"(0.1th-99.9th percentile plus a {int(BOUND_MARGIN * 100)}% margin)"
                        ),
                    ),
                )
        else:
            allowed = list(state.metadata["allowed_values"][column])
            fields[column] = (
                _literal(allowed),
                Field(..., description=f"{column}: one of {len(allowed)} categories seen in training"),
            )
    return create_model(
        "PredictionRequest", __config__=ConfigDict(extra="forbid"), **fields
    )


PredictionRequest = build_request_model(STATE)

app = FastAPI(
    title="Rwanda food-product quantity API",
    version="3.0.0",
    description=f"{STATE.model_name} predicting {STATE.target}, with online retraining.",
)

@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "model": STATE.model_name,
        "training_rows": len(STATE.training_frame),
    }


@app.get("/model-info")
def model_info() -> dict[str, Any]:
    return {
        "model_name": STATE.model_name,
        "target": STATE.target,
        "target_cap": STATE.metadata.get("target_cap"),
        "input_columns": STATE.input_columns,
        "numeric_bounds": {
            column: {"ge": STATE.bounds[column][0], "le": STATE.bounds[column][1]}
            for column in STATE.numeric_columns
        },
        "allowed_value_counts": {
            column: len(STATE.metadata["allowed_values"][column])
            for column in STATE.categorical_columns
        },
        "training_rows": len(STATE.training_frame),
        "metrics": STATE.metadata.get("metrics", {}),
    }


@app.post("/predict")
def predict(payload: PredictionRequest) -> dict[str, Any]:
    frame = pd.DataFrame([payload.model_dump()], columns=STATE.input_columns)
    try:
        prediction = float(STATE.pipeline.predict(frame)[0])
    except Exception as exc:  # pragma: no cover - defensive
        raise HTTPException(status_code=500, detail=f"Prediction failed: {exc}") from exc
    return {
        "predicted_quantity": round(max(prediction, 0.0), 2),
        "model_name": STATE.model_name,
    }


if __name__ == "__main__":
    uvicorn.run("prediction:app", host="127.0.0.1", port=8000)
