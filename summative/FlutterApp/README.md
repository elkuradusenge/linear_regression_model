# Food Price Estimator (Android)

One page, five inputs, one price in RWF. The form is rendered from
`lib/generated/form_schema.dart`, which `linear_regression/multivariate.ipynb` writes from the model
metadata. Do not edit that file by hand.

Run:

    flutter pub get
    flutter run --dart-define=API_URL=https://linear-regression-model-ycsw.onrender.com

Setup, the API contract and the end-to-end test steps live in the project README one level up.
