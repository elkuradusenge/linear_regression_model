# Linear Regression Model: Rwanda EICV5 / VUP Farming

Multivariate linear regression on
[`electricsheepafrica/africa-rwanda-eicv5-vup-farming-c5f851c8`](https://huggingface.co/datasets/electricsheepafrica/africa-rwanda-eicv5-vup-farming-c5f851c8):
a 166,044 × 38 extract of the Rwanda EICV5 survey covering VUP farming households.

## Layout

```
linear_regression_model/
├── README.md
└── summative/
    ├── pyproject.toml            # project + pinned Python (3.12) + dependencies
    ├── uv.lock                   # resolved lockfile
    ├── linear_regression/
    │   └── multivariate.ipynb    # EDA + model fitting (executed)
    ├── API/
    │   ├── prediction.py         # FastAPI service
    │   ├── requirements.txt      # runtime deps for the API
    │   └── best_model.pkl        # pipeline + feature metadata
    └── FlutterApp/               # one-page Android app (http package)
```

## Environment

Python **3.12** is pinned in `summative/pyproject.toml` (`requires-python = ">=3.12,<3.13"`).

With [uv](https://docs.astral.sh/uv/):

```bash
cd summative
uv sync
```

With the standard library only:

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install pandas numpy scikit-learn matplotlib seaborn joblib fastapi \
            uvicorn pydantic python-multipart datasets pyarrow nbformat jupyter
```

## Notebook

```bash
cd summative/linear_regression
jupyter nbconvert --to notebook --execute --inplace multivariate.ipynb
```

`multivariate.ipynb` is organised in sections A to H. It states the mission, cleans the extract,
explores it, then trains and compares four models on one test split. It finishes by saving the winning
pipeline with its metadata and by ranking products from most to least at risk.

Run it top to bottom. It rewrites `../API/best_model.pkl`.

## API

```bash
cd summative/API
pip install -r requirements.txt
uvicorn prediction:app --reload
```

| Method | Path          | Description                                        |
| ------ | ------------- | -------------------------------------------------- |
| GET    | `/health`     | Liveness probe, reports the loaded model           |
| GET    | `/model-info` | Input columns, categories, defaults and metrics    |
| POST   | `/predict`    | Predict `s8cq15` for one household product line    |

The request schema is built from the metadata stored inside `best_model.pkl`, so the service never
repeats the column list. Every field is optional; anything omitted falls back to the stored default
(the typical household), so `{}` returns the typical prediction.

```bash
curl -X POST http://127.0.0.1:8000/predict \
  -H "Content-Type: application/json" \
  -d '{"s8cq0":"Groundnut flour","district":"Gicumbi","ur":"Rural",
       "s8cq14":"Kg","s0q18m":9,"s0q18y":2017}'
# {"predicted_quantity":1093.95,"model_name":"LinearRegression"}
```

Categorical values are checked against the values seen in training. An unknown value returns 422 with
the allowed sample.

## Results

Target: `s8cq15`, reported production quantity, capped at the training 99th percentile (1,500).
15,957 train rows and 3,990 test rows.

| model                 | train MSE | test MSE |
| --------------------- | --------- | -------- |
| LinearRegression      | 16,710    | 17,431   |
| SGDRegressor          | 19,008    | 18,526   |
| RandomForestRegressor | 19,569    | 20,806   |
| DecisionTreeRegressor | 40,410    | 38,527   |

`LinearRegression` has the lowest test MSE and is saved as `best_model.pkl`. The capped forest underfits
here, because most of the signal is a product and district mean that a linear fit captures directly.
