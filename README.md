## 1. Mission and problem

A price and affordability estimator for Rwandan households, farmers and traders, and local planners.
It estimates what one food product costs per unit in a district and month.
The estimate comes from the Rwanda EICV5 survey, so it shows survey patterns rather than today's market.
The app is one page: five inputs in, one price out.

## 2. Dataset

Dataset: [`electricsheepafrica/africa-rwanda-eicv5-vup-farming-c5f851c8`](https://huggingface.co/datasets/electricsheepafrica/africa-rwanda-eicv5-vup-farming-c5f851c8) on Hugging Face,
published by the National Institute of Statistics of Rwanda through [data.gov.rw](https://data.gov.rw). It has 166,044 rows by 38 columns.
The target is the survey's unit price, `s8cq15`. About 12 percent of rows report a price, and the model uses five inputs.

## 3. Swagger UI

[`https://linear-regression-model-ycsw.onrender.com/docs`](https://linear-regression-model-ycsw.onrender.com/docs)
The service sleeps when idle, so the first request can take up to a minute.

## 4. YouTube demo

[YouTube demo](https://youtu.be/<your-demo-id>)

## 5. Run the mobile app

1. Install Flutter, then an Android emulator with `sdkmanager` and `avdmanager` (or Android Studio).
2. Clone the repository.
3. `cd summative/FlutterApp`
4. `flutter pub get`
5. Start the emulator and wait for it to boot: `emulator -avd <your-avd-name>` then `adb devices`.
6. `flutter run --dart-define=API_URL=https://linear-regression-model-ycsw.onrender.com`
7. Press `Predict` once and wait for the first request to wake the server.

The `API_URL` default is the public Render service. Omit the flag to use it. Pass another URL to point the
app somewhere else, for example `--dart-define=API_URL=http://10.0.2.2:8000` for an API on your laptop.

## What it predicts

The model predicts one number: the price in Rwandan francs (RWF) for one product, in one unit, in one
district, in one setting, in one month. It is a `LinearRegression` pipeline trained on the priced rows of
the survey. The notebook writes both the model and the app's form schema, so the phone and the API read the
same lists and ranges.

| Input | API field | Allowed values or range |
| --- | --- | --- |
| Product | `product` | 97 product names recorded in the survey, for example `Dry beans`, `Cassava leaves`, `Maize _fresh_` |
| Unit | `unit` | `Kg`, `Lit`, `Igice`, `Ipaki`, `unknown` |
| District | `district` | 27 districts, for example `Gasabo`, `Nyarugenge`, `Rubavu` |
| Setting | `ur` | `Rural`, `Urban` |
| Month | `month` | integer from 1 to 12 |

Example, from the model that is deployed:

```json
{"product": "Dry beans", "unit": "Kg", "district": "Nyarugenge", "ur": "Rural", "month": 7}
```

The API answers 520 RWF per Kg. The median for dry beans per Kg in the training rows is 500 RWF, so the
estimate sits 4 percent above it. The same request in the app shows "520 RWF per Kg" and
"Typical for this product: 500 RWF (+4%)".

## Test it end to end

Open `https://linear-regression-model-ycsw.onrender.com/docs`.

Send `POST /predict` with the sample body above. The response shape is:

```json
{
  "predicted_price_rwf": 520,
  "unit": "Kg",
  "product": "Dry beans",
  "typical_price_rwf": 500.0,
  "difference_pct": 4.0,
  "note": "Estimate from the 2016 to 2017 EICV5 survey patterns; it is not a live market price."
}
```

Send a wrong type for the month, `"month": "June"`:

```json
{"detail": [{"type": "int_parsing", "loc": ["body", "month"], "msg": "Input should be a valid integer, unable to parse string as an integer", "input": "June"}]}
```

Send `"month": 13`:

```json
{"detail": [{"type": "less_than_equal", "loc": ["body", "month"], "msg": "Input should be less than or equal to 12", "input": 13, "ctx": {"le": 12}}]}
```

Send `"product": "Unicorn meat"`:

```json
{"detail": [{"type": "literal_error", "loc": ["body", "product"], "msg": "Input should be ...", "input": "Unicorn meat", "ctx": {"expected": "..."}}]}
```

The product message is long because it lists all 97 allowed values.

All three return HTTP 422. The app turns them into one sentence each, for example
"Month must be between 1 and 12."

Upload a small CSV to `POST /retrain` with the six columns `s8cq0,s8cq14,district,ur,s0q18m,s8cq15`:

```csv
s8cq0,s8cq14,district,ur,s0q18m,s8cq15
Dry beans,Kg,Gasabo,Rural,7,520
Cassava leaves,Kg,Gasabo,Rural,7,300
Maize _fresh_,Kg,Gasabo,Urban,7,200
```

The response:

```json
{
  "status": "retrained",
  "strategy": "refit",
  "model_name": "LinearRegression",
  "rows_used": 3,
  "rows_dropped": 0,
  "training_rows": 15841,
  "holdout_mse_before": 16891.78,
  "holdout_mse_after": 17912.67,
  "saved_to_disk": true,
  "rows_received": 3,
  "dropped": {"unknown_category": 0, "month_out_of_range": 0, "invalid_price": 0},
  "rows_clipped_to_cap": 0
}
```

Repeat the sample prediction in the app. The price must match the API response. If it does not, the app and
the API are pointed at different URLs.

## Limits

The estimates reflect 2016 to 2017 survey patterns. They are not live prices.
A retrained model lives in memory and is lost when the free Render service restarts.
The winning model is `LinearRegression`, with a test MSE of 20,075.4 and a test RMSE of 141.7 RWF.
The depth-capped decision tree and random forest underfit: their training MSE of 39,384.2 and 18,758.1 is
already worse than the linear fit's 16,388.6 on the same rows.
