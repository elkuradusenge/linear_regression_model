import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;

/// The deployed API. Override it when running:
///   flutter run --dart-define=API_URL=https://your-service.onrender.com
const String apiBaseUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'https://REPLACE-WITH-YOUR-RENDER-SERVICE.onrender.com',
);

/// How long to wait before calling a request a timeout. The free Render
/// instance can take close to a minute to wake, so this is generous.
const Duration requestTimeout = Duration(seconds: 120);

/// ---------------------------------------------------------------------------
/// Input specification. This list is the only place the form is defined, so the
/// number of fields always equals the number of model inputs.
/// ---------------------------------------------------------------------------

enum FieldKind { decimal, integer, text }

class FieldSpec {
  const FieldSpec(this.label, this.jsonKey, this.kind);

  final String label;
  final String jsonKey;
  final FieldKind kind;

  bool get isNumeric => kind != FieldKind.text;

  TextInputType get keyboardType => switch (kind) {
    FieldKind.decimal => const TextInputType.numberWithOptions(decimal: true),
    FieldKind.integer => TextInputType.number,
    FieldKind.text => TextInputType.text,
  };
}

const List<FieldSpec> fieldSpecs = <FieldSpec>[
  FieldSpec('Product (s8cq0)', 's8cq0', FieldKind.text),
  FieldSpec('District', 'district', FieldKind.text),
  FieldSpec('Urban or rural (Rural / Urban)', 'ur', FieldKind.text),
  FieldSpec('Unit (Kg / Lit / Igice / Ipaki)', 's8cq14', FieldKind.text),
  FieldSpec('COICOP group (01 / 02 / 04)', 'coicop_group', FieldKind.text),
  FieldSpec('Share s8cq5', 's8cq5', FieldKind.decimal),
  FieldSpec('Share s8cq6', 's8cq6', FieldKind.decimal),
  FieldSpec('Share s8cq7', 's8cq7', FieldKind.decimal),
  FieldSpec('Share s8cq8', 's8cq8', FieldKind.decimal),
  FieldSpec('Share s8cq9', 's8cq9', FieldKind.decimal),
  FieldSpec('Share s8cq10', 's8cq10', FieldKind.decimal),
  FieldSpec('Share s8cq11', 's8cq11', FieldKind.decimal),
  FieldSpec('Share s8cq12', 's8cq12', FieldKind.decimal),
  FieldSpec('Share s8cq13', 's8cq13', FieldKind.decimal),
  FieldSpec('Interview month (1-12)', 's0q18m', FieldKind.integer),
  FieldSpec('Interview year (2016-2017)', 's0q18y', FieldKind.integer),
];

String labelFor(String jsonKey) {
  for (final spec in fieldSpecs) {
    if (spec.jsonKey == jsonKey) return spec.label;
  }
  return jsonKey;
}

/// ---------------------------------------------------------------------------
/// API service. One function, one URL constant.
/// ---------------------------------------------------------------------------

class PredictionResult {
  const PredictionResult.value(this.prediction)
    : messages = const <String>[],
      isError = false;

  const PredictionResult.error(this.messages)
    : prediction = null,
      isError = true;

  final double? prediction;
  final List<String> messages;
  final bool isError;
}

Future<PredictionResult> requestPrediction(Map<String, dynamic> payload) async {
  try {
    final http.Response response = await http
        .post(
          Uri.parse('$apiBaseUrl/predict'),
          headers: const <String, String>{'Content-Type': 'application/json'},
          body: jsonEncode(payload),
        )
        .timeout(requestTimeout);

    if (response.statusCode == 200) {
      final dynamic body = jsonDecode(response.body);
      final num? value = body is Map
          ? body['predicted_quantity'] as num?
          : null;
      if (value == null) {
        return const PredictionResult.error(<String>[
          'The API replied without a prediction value.',
        ]);
      }
      return PredictionResult.value(value.toDouble());
    }

    if (response.statusCode == 422) {
      return PredictionResult.error(messagesFromValidation(response.body));
    }

    return PredictionResult.error(<String>[
      'The API returned HTTP ${response.statusCode}.',
    ]);
  } on TimeoutException {
    return const PredictionResult.error(<String>[
      'The request timed out. The free Render service can take up to a minute to wake, '
          'so please try again.',
    ]);
  } on SocketException {
    return const PredictionResult.error(<String>[
      'No network connection. Check the phone or emulator connection and try again.',
    ]);
  } on http.ClientException {
    return const PredictionResult.error(<String>[
      'Could not reach the API. Check the URL and that the Render service is awake.',
    ]);
  } on FormatException {
    return const PredictionResult.error(<String>[
      'The API sent a response this app could not read.',
    ]);
  }
}

/// Turns FastAPI's 422 `detail` list into one plain sentence per field.
List<String> messagesFromValidation(String responseBody) {
  final List<String> messages = <String>[];

  dynamic detail;
  try {
    final dynamic decoded = jsonDecode(responseBody);
    detail = decoded is Map ? decoded['detail'] : null;
  } on FormatException {
    return <String>[
      'The API rejected the request but the reply could not be read.',
    ];
  }

  if (detail is List) {
    for (final dynamic item in detail) {
      messages.add(messageFromDetailItem(item));
    }
  } else if (detail is String) {
    messages.add(detail);
  } else if (detail is Map) {
    messages.add(messageFromDetailItem(detail));
  }

  if (messages.isEmpty) {
    messages.add('The API rejected the request. Check every field.');
  }
  return messages;
}

String messageFromDetailItem(dynamic item) {
  if (item is! Map) return item.toString();

  final String type = item['type']?.toString() ?? '';
  final dynamic loc = item['loc'];
  final String key = loc is List && loc.isNotEmpty
      ? loc.last.toString()
      : 'Request';
  final String label = key == 'body' ? 'Request' : labelFor(key);
  final Map<dynamic, dynamic> ctx = item['ctx'] is Map
      ? item['ctx'] as Map<dynamic, dynamic>
      : <dynamic, dynamic>{};

  return switch (type) {
    'missing' => '$label is required.',
    'float_parsing' ||
    'int_parsing' ||
    'float_type' ||
    'int_type' => '$label must be a number.',
    'greater_than_equal' =>
      '$label must be at least ${formatBound(ctx['ge'])}.',
    'less_than_equal' => '$label must be at most ${formatBound(ctx['le'])}.',
    'literal_error' =>
      '$label must be one of the values the model was trained on.',
    'extra_forbidden' => '$label is not a field this model accepts.',
    _ => '$label is invalid (${item['msg'] ?? 'no reason given'}).',
  };
}

String formatBound(dynamic value) {
  if (value is num) {
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(2);
  }
  return value?.toString() ?? '';
}

void main() => runApp(
  const MaterialApp(
    home: Scaffold(body: Center(child: Text('Field definitions ready.'))),
  ),
);
