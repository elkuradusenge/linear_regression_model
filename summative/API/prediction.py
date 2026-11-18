"""Prediction and retraining API for the Rwandan food-product quantity model.

The feature contract, the numeric bounds and the categorical vocabulary all come
from the artifacts stored beside this file, so they are defined in one place.

Run it:
    uvicorn prediction:app --reload
    python prediction.py
"""

import io
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

import joblib
import pandas as pd
import uvicorn
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, ConfigDict, Field, create_model
from sklearn.base import clone
from sklearn.metrics import mean_squared_error
from sklearn.model_selection import train_test_split

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

# CORS, because the Flutter web build calls this API from the browser and the browser
# blocks cross-origin calls unless the API opts in. Allowed: GET and POST from the two
# origins listed below, carrying only a Content-Type header. Restricted: no wildcard
# origin, so random sites cannot read responses; no PUT/PATCH/DELETE; no custom
# headers; and credentials off because this API sets no cookies and has no login.
# A native Flutter build on Android or iOS is not affected by CORS at all, since CORS
# is enforced by browsers, not by the phone: the mobile app can call this API from any
# origin. Only the web build needs these entries.
ALLOWED_ORIGINS = [
    "https://REPLACE-WITH-YOUR-RENDER-SERVICE.onrender.com",  # deployed API on Render
    "http://localhost:8080",  # Flutter web debug server
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type"],
    allow_credentials=False,
)


def _check_columns(frame: pd.DataFrame, state: ModelState) -> tuple[pd.DataFrame, list[str]]:
    required = state.training_columns
    missing = [column for column in required if column not in frame.columns]
    if missing:
        raise HTTPException(
            status_code=422,
            detail={
                "status": "rejected",
                "reason": "columns do not match the training columns",
                "missing_columns": missing,
                "expected_columns": required,
            },
        )
    ignored = [str(column) for column in frame.columns if column not in required]
    return frame.loc[:, required].copy(), ignored


def _clean_upload(frame: pd.DataFrame, state: ModelState) -> tuple[pd.DataFrame, dict[str, Any]]:
    """Coerce types, drop unusable rows and report what was dropped."""
    work, ignored = _check_columns(frame, state)
    received = len(work)

    for column in state.numeric_columns + [state.target]:
        work[column] = pd.to_numeric(work[column], errors="coerce")

    blanks = 0
    for column in state.categorical_columns:
        stripped = work[column].astype("string").str.strip()
        blanks += int((stripped == "").sum())
        work[column] = stripped.mask(stripped == "", pd.NA)

    before = len(work)
    work = work.dropna(subset=state.training_columns)
    missing_rows = before - len(work)

    non_positive = int((work[state.target] <= 0).sum())
    work = work.loc[work[state.target] > 0]

    cap = float(state.metadata.get("target_cap") or work[state.target].max())
    clipped = int((work[state.target] > cap).sum())
    work[state.target] = work[state.target].clip(upper=cap)

    report = {
        "rows_received": received,
        "rows_used_after_cleaning": len(work),
        "rows_dropped": received - len(work),
        "dropped_reasons": {
            "missing_or_non_numeric": missing_rows,
            "blank_categories": blanks,
            "non_positive_target": non_positive,
        },
        "adjusted": {"rows_clipped_to_target_cap": clipped},
        "ignored_columns": ignored,
    }
    return work.reset_index(drop=True), report


def _partial_fit(state: ModelState, new_rows: pd.DataFrame) -> dict[str, Any]:
    """SGD path: reuse the fitted preprocessor and call partial_fit."""
    preprocessor = state.pipeline.named_steps["prep"]
    model = state.pipeline.named_steps["model"]

    features = preprocessor.transform(new_rows[state.input_columns])
    try:
        model.partial_fit(features, new_rows[state.target].to_numpy(dtype=float))
    except ValueError as exc:
        raise HTTPException(
            status_code=409,
            detail=f"partial_fit is not available for the loaded model: {exc}",
        ) from exc

    holdout = state.training_frame.sample(frac=HOLDOUT_FRACTION, random_state=RANDOM_STATE)
    predictions = model.predict(preprocessor.transform(holdout[state.input_columns]))
    return {
        "pipeline": state.pipeline,
        "model_name": type(model).__name__,
        "strategy": "partial_fit",
        "rows_used": len(state.training_frame) + len(new_rows),
        "holdout_mse": float(mean_squared_error(holdout[state.target], predictions)),
    }


def _refit(state: ModelState, new_rows: pd.DataFrame) -> dict[str, Any]:
    """Other models: refit on the stored cleaned data plus the new rows."""
    combined = pd.concat(
        [state.training_frame[state.training_columns], new_rows], ignore_index=True
    )
    features = combined[state.input_columns]
    cap = float(state.metadata.get("target_cap") or combined[state.target].max())
    target = combined[state.target].clip(upper=cap)
    combined = combined.assign(**{state.target: target})

    x_train, x_test, y_train, y_test = train_test_split(
        features, target, test_size=HOLDOUT_FRACTION, random_state=RANDOM_STATE
    )
    scored = clone(state.pipeline).fit(x_train, y_train)
    holdout_mse = float(mean_squared_error(y_test, scored.predict(x_test)))

    final = clone(state.pipeline).fit(features, target)
    state.training_frame = combined
    return {
        "pipeline": final,
        "model_name": type(final.named_steps["model"]).__name__,
        "strategy": "refit",
        "rows_used": len(combined),
        "holdout_mse": holdout_mse,
    }


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


@app.post("/retrain")
async def retrain(file: UploadFile = File(...)) -> dict[str, Any]:
    contents = await file.read()
    if not contents:
        raise HTTPException(status_code=422, detail="The uploaded file is empty.")

    try:
        uploaded = pd.read_csv(io.BytesIO(contents))
    except Exception as exc:
        raise HTTPException(status_code=422, detail=f"Could not parse the CSV: {exc}") from exc

    prepared, report = _clean_upload(uploaded, STATE)
    if prepared.empty:
        raise HTTPException(
            status_code=422,
            detail={"status": "rejected", "reason": "no usable rows after cleaning", **report},
        )

    if STATE.model_name == "SGDRegressor":
        outcome = _partial_fit(STATE, prepared)
    else:
        outcome = _refit(STATE, prepared)

    STATE.pipeline = outcome["pipeline"]
    STATE.metadata["model_name"] = outcome["model_name"]
    STATE.metadata.setdefault("metrics", {})[outcome["model_name"]] = {
        "test_mse": round(outcome["holdout_mse"], 2),
        "trained_rows": outcome["rows_used"],
        "source": "retrain",
    }
    joblib.dump({"pipeline": STATE.pipeline, "metadata": STATE.metadata}, MODEL_PATH)

    return {
        "status": "retrained",
        "strategy": outcome["strategy"],
        "model_name": outcome["model_name"],
        "rows_used": outcome["rows_used"],
        "new_rows_used": len(prepared),
        "holdout_mse": round(outcome["holdout_mse"], 2),
        "saved_to": MODEL_PATH.name,
        **report,
    }


if __name__ == "__main__":
    uvicorn.run("prediction:app", host="127.0.0.1", port=8000)
