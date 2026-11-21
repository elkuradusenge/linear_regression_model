import 'dart:async';
import 'dart:convert';

// The SDK deprecates this import in favour of package:material_ui, but keeping the
// framework's own Material library means the app needs no package beyond http.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'generated/form_schema.dart';

/// API origin, overridden per run:
///   flutter run --dart-define=API_URL=https://your-service.onrender.com
const String apiBaseUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'https://linear-regression-model-ycsw.onrender.com',
);

/// The free Render instance sleeps, so the first prediction may wait for a cold start.
const Duration firstCallTimeout = Duration(seconds: 70);
const Duration laterCallTimeout = Duration(seconds: 15);

const double pagePadding = 16;

const String idleLine =
    'Estimates the unit price in RWF of one food product for one month.';

void main() => runApp(const FoodPriceApp());

/// The one page: every input is rendered from [fieldSpecs], which the notebook wrote.
class FoodPriceApp extends StatelessWidget {
  const FoodPriceApp({super.key, this.service});

  final PriceService? service;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Food Price Estimator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        ),
      ),
      home: PredictionPage(service: service),
    );
  }
}

/// ---------------------------------------------------------------------------
/// Result of one prediction and the four states of the card.
/// ---------------------------------------------------------------------------

class PriceResult {
  const PriceResult({
    required this.price,
    required this.typicalPrice,
    required this.differencePct,
    required this.product,
    required this.unit,
    required this.note,
  });

  final int price;
  final double typicalPrice;
  final double differencePct;
  final String product;
  final String unit;
  final String note;
}

enum CardPhase { idle, loading, success, error }

class CardState {
  const CardState({
    required this.phase,
    this.price,
    this.message,
    this.firstRequest = false,
  });

  const CardState.idle() : this(phase: CardPhase.idle);

  const CardState.loading({required bool firstRequest})
    : this(phase: CardPhase.loading, firstRequest: firstRequest);

  CardState.success(PriceResult result)
    : this(phase: CardPhase.success, price: result);

  const CardState.error(String message)
    : this(phase: CardPhase.error, message: message);

  final CardPhase phase;
  final PriceResult? price;
  final String? message;
  final bool firstRequest;
}

class PredictOutcome {
  const PredictOutcome.success(this.result) : error = null;

  const PredictOutcome.failure(this.error) : result = null;

  final PriceResult? result;
  final String? error;
}

/// ---------------------------------------------------------------------------
/// The service: one client, one base URL, one prediction function.
/// ---------------------------------------------------------------------------

abstract class PriceService {
  Future<PredictOutcome> predict(Map<String, Object?> body);
}

class ApiService implements PriceService {
  ApiService({String baseUrl = apiBaseUrl}) : _base = _withoutTrailingSlash(baseUrl) {
    unawaited(_wake());
  }

  final String _base;
  final http.Client _client = http.Client();
  bool _answeredOnce = false;

  /// One fire-and-forget GET /docs, so the free instance starts while the user types.
  Future<void> _wake() async {
    try {
      await _client.get(Uri.parse('$_base/docs')).timeout(firstCallTimeout);
    } on Exception {
      // Best effort only: a real failure is reported by the prediction call.
    }
  }

  @override
  Future<PredictOutcome> predict(Map<String, Object?> body) async {
    try {
      final http.Response response = await _client
          .post(
            Uri.parse('$_base/predict'),
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_answeredOnce ? laterCallTimeout : firstCallTimeout);

      _answeredOnce = true;

      if (response.statusCode == 200) {
        try {
          return PredictOutcome.success(parsePrediction(response.body));
        } on FormatException catch (error) {
          return PredictOutcome.failure(error.message);
        }
      }
      if (response.statusCode == 422) {
        return PredictOutcome.failure(messageFromValidation(response.body));
      }
      return PredictOutcome.failure(
        'The API returned HTTP ${response.statusCode}. Please try again.',
      );
    } on TimeoutException {
      return const PredictOutcome.failure(
        'The request timed out. The free server may still be waking, so try again.',
      );
    } on http.ClientException {
      return const PredictOutcome.failure(
        'Could not reach the API. Check the network and the API_URL you built with.',
      );
    } on FormatException {
      return const PredictOutcome.failure(
        'The API sent a response this app could not read.',
      );
    } catch (_) {
      return const PredictOutcome.failure(
        'Could not reach the API. Check the network and the API_URL you built with.',
      );
    }
  }
}

String _withoutTrailingSlash(String value) {
  final String trimmed = value.trim();
  return trimmed.endsWith('/')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}

/// Reads the 200 body. The price range comes from the generated schema, never from here.
PriceResult parsePrediction(String body) {
  final dynamic decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('The API sent a response this app could not read.');
  }

  final num? price = decoded['predicted_price_rwf'] as num?;
  final num? typical = decoded['typical_price_rwf'] as num?;
  final num? difference = decoded['difference_pct'] as num?;
  final String? product = decoded['product'] as String?;
  final String? unit = decoded['unit'] as String?;
  final String? note = decoded['note'] as String?;

  if (price == null ||
      typical == null ||
      difference == null ||
      product == null ||
      unit == null) {
    throw const FormatException('The API replied without a price.');
  }
  if (price < priceMin || price > priceMax) {
    throw FormatException(
      'The API returned ${price.round()} RWF, outside the model range of '
      '${priceMin.round()}-${priceMax.round()} RWF.',
    );
  }

  return PriceResult(
    price: price.round(),
    typicalPrice: typical.toDouble(),
    differencePct: difference.toDouble(),
    product: product,
    unit: unit,
    note: note ?? '',
  );
}

/// Turns FastAPI's 422 `detail` into one readable sentence naming field and range.
String messageFromValidation(String responseBody) {
  final dynamic detail = _detailFrom(responseBody);
  final Map<dynamic, dynamic> item = _firstDetailItem(detail);
  if (item.isEmpty) {
    return detail is String
        ? detail
        : 'The API rejected the request. Check every field.';
  }

  final String key = _fieldKey(item);
  final FieldSpec? spec = _specOrNull(key);
  final String label = spec?.label ?? 'The request';
  final String type = item['type']?.toString() ?? '';

  switch (type) {
    case 'missing':
      return '$label is required.';
    case 'int_parsing':
    case 'float_parsing':
    case 'int_type':
    case 'float_type':
      return spec == null ? '$label must be a number.' : allowedMessage(spec);
    case 'greater_than_equal':
    case 'less_than_equal':
      return spec == null
          ? '$label is out of range.'
          : allowedMessage(spec);
    case 'literal_error':
      return spec == null ? '$label is not an allowed value.' : allowedMessage(spec);
    default:
      return '$label is invalid (${item['msg'] ?? 'no reason given'}).';
  }
}

dynamic _detailFrom(String responseBody) {
  try {
    final dynamic decoded = jsonDecode(responseBody);
    return decoded is Map ? decoded['detail'] : null;
  } on FormatException {
    return null;
  }
}

Map<dynamic, dynamic> _firstDetailItem(dynamic detail) {
  if (detail is List && detail.isNotEmpty && detail.first is Map) {
    return detail.first as Map<dynamic, dynamic>;
  }
  if (detail is Map) {
    return detail;
  }
  return <dynamic, dynamic>{};
}

String _fieldKey(Map<dynamic, dynamic> item) {
  final dynamic loc = item['loc'];
  if (loc is List && loc.isNotEmpty) {
    final dynamic last = loc.last;
    if (last is String && last != 'body') {
      return last;
    }
  }
  return '';
}

FieldSpec? _specOrNull(String key) {
  for (final FieldSpec spec in fieldSpecs) {
    if (spec.key == key) {
      return spec;
    }
  }
  return null;
}

/// The allowed range of a field, phrased for a one-line error.
String allowedMessage(FieldSpec spec) {
  if (spec.kind == FieldKind.month) {
    return '${spec.label} must be between ${spec.minValue} and ${spec.maxValue}.';
  }
  if (spec.values.length <= 6) {
    return '${spec.label} must be one of: ${spec.values.join(', ')}.';
  }
  return '${spec.label} must be one of the ${spec.values.length} values the '
      'model was trained on.';
}

/// 1250 -> "1,250". No intl package: three digits at a time is enough here.
String formatThousands(int value) {
  final String digits = value.abs().toString();
  final StringBuffer buffer = StringBuffer();
  for (int index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(digits[index]);
  }
  return value < 0 ? '-$buffer' : buffer.toString();
}

String formatPercent(double value) {
  final int rounded = value.round();
  return rounded > 0 ? '+$rounded%' : '$rounded%';
}

/// ---------------------------------------------------------------------------
/// The one reusable input widget, rendered from a FieldSpec.
/// ---------------------------------------------------------------------------

class SchemaField extends StatelessWidget {
  const SchemaField({
    super.key,
    required this.spec,
    this.controller,
    this.focusNode,
    this.enabled = true,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
    this.selection,
    this.onSelectionChanged,
  });

  final FieldSpec spec;

  /// Set for the text inputs and left null for the setting, which has no text.
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final bool enabled;
  final TextInputAction textInputAction;
  final VoidCallback? onSubmitted;
  final String? selection;
  final ValueChanged<String>? onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(spec.label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        if (spec.kind == FieldKind.setting)
          _settingField()
        else
          _textField(),
      ],
    );
  }

  Widget _settingField() {
    return SegmentedButton<String>(
      segments: <ButtonSegment<String>>[
        for (final String value in spec.values)
          ButtonSegment<String>(value: value, label: Text(value)),
      ],
      selected: <String>{selection ?? spec.values.first},
      onSelectionChanged: enabled && onSelectionChanged != null
          ? (Set<String> values) => onSelectionChanged!(values.first)
          : null,
      showSelectedIcon: false,
      expandedInsets: EdgeInsets.zero,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
    );
  }

  Widget _textField() {
    if (spec.kind == FieldKind.month) {
      return TextField(
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        keyboardType: TextInputType.number,
        textInputAction: textInputAction,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
        ],
        onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
        decoration: InputDecoration(
          hintText: '${spec.minValue}-${spec.maxValue}',
        ),
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return Autocomplete<String>(
          textEditingController: controller,
          focusNode: focusNode,
          optionsMaxHeight: 220,
          optionsBuilder: (TextEditingValue value) {
            final String query = value.text.trim().toLowerCase();
            if (query.isEmpty) {
              return const Iterable<String>.empty();
            }
            return spec.values
                .where((String option) => option.toLowerCase().contains(query))
                .take(6);
          },
          fieldViewBuilder: (
            BuildContext context,
            TextEditingController fieldController,
            FocusNode fieldFocus,
            VoidCallback onFieldSubmitted,
          ) {
            return TextField(
              controller: fieldController,
              focusNode: fieldFocus,
              enabled: enabled,
              textInputAction: textInputAction,
              onSubmitted: (_) {
                onFieldSubmitted();
                onSubmitted?.call();
              },
              decoration: const InputDecoration(hintText: 'Start typing'),
            );
          },
          optionsViewBuilder: (
            BuildContext context,
            AutocompleteOnSelected<String> onSelected,
            Iterable<String> options,
          ) {
            final List<String> visible = options.toList();
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: (visible.length * 44).clamp(44, 220).toDouble(),
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: visible.length,
                    itemBuilder: (BuildContext context, int index) {
                      final String option = visible[index];
                      return InkWell(
                        onTap: () => onSelected(option),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          child: Text(
                            option,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// ---------------------------------------------------------------------------
/// The only display area: one card, four states.
/// ---------------------------------------------------------------------------

class ResultCard extends StatelessWidget {
  const ResultCard({super.key, required this.state});

  final CardState state;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 104),
      padding: const EdgeInsets.all(pagePadding),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: switch (state.phase) {
        CardPhase.idle => const Text(idleLine),
        CardPhase.loading => Row(
          children: <Widget>[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                state.firstRequest
                    ? 'Waking the server, this can take up to a minute.'
                    : 'Predicting...',
              ),
            ),
          ],
        ),
        CardPhase.success => _SuccessBody(result: state.price!),
        CardPhase.error => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              Icons.error_outline,
              size: 18,
              color: theme.colorScheme.error,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(state.message ?? 'Something went wrong.')),
          ],
        ),
      },
    );
  }
}

class _SuccessBody extends StatelessWidget {
  const _SuccessBody({required this.result});

  final PriceResult result;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String unit = result.unit == 'unknown' ? 'unit' : result.unit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          '${formatThousands(result.price)} $targetPriceUnit per $unit',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Typical for this product: '
          '${formatThousands(result.typicalPrice.round())} $targetPriceUnit '
          '(${formatPercent(result.differencePct)})',
        ),
        const SizedBox(height: 8),
        Text(result.note, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

/// ---------------------------------------------------------------------------
/// The page.
/// ---------------------------------------------------------------------------

class PredictionPage extends StatefulWidget {
  const PredictionPage({super.key, this.service});

  final PriceService? service;

  @override
  State<PredictionPage> createState() => _PredictionPageState();
}

class _PredictionPageState extends State<PredictionPage> {
  late final PriceService _service;
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};
  final Map<String, FocusNode> _focusNodes = <String, FocusNode>{};
  final ValueNotifier<CardState> _card = ValueNotifier<CardState>(
    const CardState.idle(),
  );

  late String _setting = settingValues.first;
  bool _busy = false;
  bool _firstPrediction = true;

  @override
  void initState() {
    super.initState();
    // ApiService wakes the free server in its constructor, without blocking the UI.
    _service = widget.service ?? ApiService();
    for (final FieldSpec spec in fieldSpecs) {
      if (spec.kind == FieldKind.setting) {
        continue;
      }
      _controllers[spec.key] = TextEditingController();
      _focusNodes[spec.key] = FocusNode();
    }
    _controllers['month']!.text = DateTime.now().month.toString();
  }

  @override
  void dispose() {
    for (final TextEditingController controller in _controllers.values) {
      controller.dispose();
    }
    for (final FocusNode node in _focusNodes.values) {
      node.dispose();
    }
    _card.dispose();
    super.dispose();
  }

  /// The reusable row entry point: layout picks the key, the schema owns the rest.
  Widget _field(String key, {TextInputAction action = TextInputAction.next}) {
    final FieldSpec spec = specFor(key);
    return SchemaField(
      key: ValueKey<String>(key),
      spec: spec,
      controller: _controllers[key],
      focusNode: _focusNodes[key],
      enabled: !_busy,
      textInputAction: action,
      onSubmitted: action == TextInputAction.done ? _submit : null,
      selection: key == 'ur' ? _setting : null,
      onSelectionChanged: (String value) => setState(() => _setting = value),
    );
  }

  Future<void> _submit() async {
    if (_busy) {
      return;
    }

    final Map<String, Object?>? payload = _validatedPayload();
    if (payload == null) {
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    _card.value = CardState.loading(firstRequest: _firstPrediction);

    final PredictOutcome outcome = await _service.predict(payload);

    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    _firstPrediction = false;
    _card.value = outcome.result != null
        ? CardState.success(outcome.result!)
        : CardState.error(outcome.error!);
  }

  /// Checks what the phone can check, so most mistakes never reach the network.
  Map<String, Object?>? _validatedPayload() {
    final Map<String, Object?> payload = <String, Object?>{};

    for (final FieldSpec spec in fieldSpecs) {
      if (spec.kind == FieldKind.setting) {
        payload[spec.key] = _setting;
        continue;
      }

      final TextEditingController controller = _controllers[spec.key]!;
      final String raw = controller.text.trim();
      if (raw.isEmpty) {
        _card.value = CardState.error('${spec.label} is required.');
        return null;
      }

      if (spec.kind == FieldKind.month) {
        final int? month = int.tryParse(raw);
        if (month == null || month < monthMin || month > monthMax) {
          _card.value = CardState.error(allowedMessage(spec));
          return null;
        }
        payload[spec.key] = month;
        continue;
      }

      final String? canonical = _canonicalValue(spec, raw);
      if (canonical == null) {
        _card.value = CardState.error(allowedMessage(spec));
        return null;
      }
      if (canonical != controller.text) {
        controller.text = canonical;
      }
      payload[spec.key] = canonical;
    }
    return payload;
  }

  String? _canonicalValue(FieldSpec spec, String raw) {
    final String needle = raw.toLowerCase();
    for (final String value in spec.values) {
      if (value.toLowerCase() == needle) {
        return value;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        toolbarHeight: 48,
        titleSpacing: pagePadding,
        title: const Text(
          'Food Price Estimator',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool keyboardOpen =
                MediaQuery.viewInsetsOf(context).bottom > 0;
            final double minHeight = constraints.maxHeight > 2 * pagePadding
                ? constraints.maxHeight - 2 * pagePadding
                : 0;
            return SingleChildScrollView(
              physics: keyboardOpen
                  ? const ClampingScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.all(pagePadding),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: minHeight),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _field('product'),
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        Expanded(child: _field('unit')),
                        const SizedBox(width: 12),
                        Expanded(child: _field('month')),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          child: _field(
                            'district',
                            action: TextInputAction.done,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: _field('ur')),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 48,
                      child: FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: const Text(
                          'Predict',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    ValueListenableBuilder<CardState>(
                      valueListenable: _card,
                      builder:
                          (
                            BuildContext context,
                            CardState state,
                            Widget? child,
                          ) => ResultCard(state: state),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
