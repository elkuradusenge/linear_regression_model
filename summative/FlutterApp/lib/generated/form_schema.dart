// GENERATED FILE - DO NOT EDIT BY HAND.
// Written by linear_regression/multivariate.ipynb (cell G2) from best_model.pkl.
// The API and this app read the same metadata, so neither defines a list or a range alone.

/// How the phone collects one model input.
enum FieldKind { product, unit, district, setting, month }

/// One input of POST /predict, in the order the API expects.
class FieldSpec {
  const FieldSpec({
    required this.key,
    required this.label,
    required this.kind,
    required this.values,
    this.minValue,
    this.maxValue,
  });

  /// JSON key sent to the API.
  final String key;

  /// Label shown above the input.
  final String label;

  final FieldKind kind;

  /// Every value the model was trained on, empty for the numeric month.
  final List<String> values;

  /// Inclusive bounds, set only for the month.
  final int? minValue;
  final int? maxValue;
}

const String modelName = 'LinearRegression';
const String targetPriceUnit = 'RWF';
const int monthMin = 1;
const int monthMax = 12;
const double priceMin = 13.48;
const double priceMax = 1575.0;

const List<String> productValues = <String>[
  'Amarante _large leafed green_',
  'Amarante _small leafed green_',
  'Avocado',
  'Banana - beer _Ikakama/Inkashi_',
  'Banana - cooking _Inyamunyo_',
  'Banana fruit _Imineke_',
  'Beef meat',
  'Berries',
  'Butter _local_',
  'Cabbages',
  'Carrot',
  'Cassava _fermented_',
  'Cassava _root_',
  'Cassava flour _yasekuwe_',
  'Cassava from Mill_',
  'Cassava leaves',
  'Celery',
  'Charcoal _cooking_',
  'Cheese',
  'Chicken live',
  'Citron - Lemon',
  'Coffee _local_',
  'Construction wood',
  'Corn _flour from Mill_',
  'Cucumber',
  'Curdled Milk',
  'Dried tobacco leaves',
  'Dry beans',
  'Dry maize _grain_',
  'Eggplant',
  'Eggs',
  'Fresh bean',
  'Fresh milk',
  'Garlic',
  'Goat meat',
  'Green pea _dry_',
  'Green pea _fresh_',
  'Ground nuts _peanuts_',
  'Groundnut flour',
  'Guava',
  'Honey',
  'Ibishayote',
  'Irish Potato',
  'Lard of pork',
  'Leeks',
  'Local Banana beer',
  'Local banana juice',
  'Local rice',
  'Local sorghum beer_ikigage_',
  'Maize _fresh_',
  'Mangos',
  'Millet _flour_',
  'Mushrooms',
  'Onion',
  'Orange _local_',
  'Other Meats',
  'Other Vegetables',
  'Other animal fats',
  'Other cereals',
  'Other domestic poultries eg ducks',
  'Other flour of cereals',
  'Other fruits',
  'Other juices of fruits _local_',
  'Other tubers',
  'Papayas',
  'Parsley',
  'Passion Fruit',
  'Passion fruit juice',
  'Pepper',
  'Pepper-raw',
  'Pepper_ground / liquid_',
  'Pineapple',
  'Plums',
  'Pork meat',
  'Pumpkin',
  'Rabbit Meat',
  'Sheep /Mutton / lamb meat',
  'Small Sized Fish _fresh_',
  'Sorghum',
  'Sorghum _flour_',
  'Sorghum juice_Ubushera_',
  'Soya Flour',
  'Soya _dry_',
  'Soya _fresh_',
  'Spinach',
  'String bean',
  'Sugarcane',
  'Sunflower Flour',
  'Sweet potato',
  'Tangerine',
  'Tarot/amateke',
  'Tea _local_',
  'Tomato',
  'Wheat _flour_',
  'Wheat _grain_',
  'Wood _cooking_',
  'Yams/Ibikoro',
];

const List<String> unitValues = <String>[
  'Igice',
  'Ipaki',
  'Kg',
  'Lit',
  'unknown',
];

const List<String> districtValues = <String>[
  'Bugesera',
  'Gakenke',
  'Gasabo',
  'Gatsibo',
  'Gicumbi',
  'Gisagara',
  'Huye',
  'Kamonyi',
  'Karongi',
  'Kicukiro',
  'Kirehe',
  'Muhanga',
  'Musanze',
  'Ngoma',
  'Ngororero',
  'Nyabihu',
  'Nyagatare',
  'Nyamagabe',
  'Nyamasheke',
  'Nyarugenge',
  'Nyaruguru',
  'Rubavu',
  'Ruhango',
  'Rulindo',
  'Rusizi',
  'Rutsiro',
  'Rwamagana',
];

const List<String> settingValues = <String>[
  'Rural',
  'Urban',
];

const List<FieldSpec> fieldSpecs = <FieldSpec>[
  FieldSpec(
    key: 'product',
    label: 'Product',
    kind: FieldKind.product,
    values: productValues,
  ),
  FieldSpec(
    key: 'unit',
    label: 'Unit',
    kind: FieldKind.unit,
    values: unitValues,
  ),
  FieldSpec(
    key: 'district',
    label: 'District',
    kind: FieldKind.district,
    values: districtValues,
  ),
  FieldSpec(
    key: 'ur',
    label: 'Setting',
    kind: FieldKind.setting,
    values: settingValues,
  ),
  FieldSpec(
    key: 'month',
    label: 'Month',
    kind: FieldKind.month,
    values: <String>[],
    minValue: monthMin,
    maxValue: monthMax,
  ),
];

/// The spec for one API field; throws rather than inventing a fallback.
FieldSpec specFor(String key) {
  for (final FieldSpec spec in fieldSpecs) {
    if (spec.key == key) {
      return spec;
    }
  }
  throw ArgumentError.value(key, 'key', 'not a field in form_schema.dart');
}
