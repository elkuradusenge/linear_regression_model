import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/generated/form_schema.dart';
import 'package:flutter_app/main.dart';

class _FakeService implements PriceService {
  _FakeService(this.outcome);

  final PredictOutcome outcome;
  Map<String, Object?>? lastBody;

  @override
  Future<PredictOutcome> predict(Map<String, Object?> body) async {
    lastBody = body;
    return outcome;
  }
}

class _SlowService implements PriceService {
  final Completer<PredictOutcome> completer = Completer<PredictOutcome>();

  @override
  Future<PredictOutcome> predict(Map<String, Object?> body) => completer.future;
}

const PriceResult _sampleResult = PriceResult(
  price: 1250,
  typicalPrice: 1100,
  differencePct: 13.636,
  product: 'Dry beans',
  unit: 'Kg',
  note:
      'Estimate from the 2016 to 2017 EICV5 survey patterns; it is not a live '
      'market price.',
);

PredictOutcome get _success => const PredictOutcome.success(_sampleResult);

Future<void> _fillForm(WidgetTester tester) async {
  final Finder fields = find.byType(TextField);
  await tester.enterText(fields.at(0), 'Dry beans');
  await tester.enterText(fields.at(1), 'Kg');
  await tester.enterText(fields.at(3), 'Gasabo');
}

void main() {
  testWidgets('renders the title, four inputs, the button and the idle card', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(FoodPriceApp(service: _FakeService(_success)));

    expect(find.text('Food Price Estimator'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(4));
    expect(find.text('Predict'), findsOneWidget);
    expect(find.text(idleLine), findsOneWidget);
    // The setting is a segmented control, not a fifth text field.
    expect(find.byType(SegmentedButton<String>), findsOneWidget);
  });

  testWidgets('reports an empty field without calling the API', (
    WidgetTester tester,
  ) async {
    final _FakeService service = _FakeService(_success);
    await tester.pumpWidget(FoodPriceApp(service: service));

    await tester.tap(find.text('Predict'));
    await tester.pump();

    expect(find.text('Product is required.'), findsOneWidget);
    expect(service.lastBody, isNull);
  });

  testWidgets('rejects an unknown product before sending', (
    WidgetTester tester,
  ) async {
    final _FakeService service = _FakeService(_success);
    await tester.pumpWidget(FoodPriceApp(service: service));

    await tester.enterText(find.byType(TextField).at(0), 'Unicorn meat');
    await tester.tap(find.text('Predict'));
    await tester.pump();

    expect(
      find.text(
        'Product must be one of the ${productValues.length} values the model '
        'was trained on.',
      ),
      findsOneWidget,
    );
    expect(service.lastBody, isNull);
  });

  testWidgets('rejects month 13 with the generated range', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(FoodPriceApp(service: _FakeService(_success)));

    await _fillForm(tester);
    await tester.enterText(find.byType(TextField).at(2), '13');
    await tester.tap(find.text('Predict'));
    await tester.pump();

    expect(
      find.text('Month must be between $monthMin and $monthMax.'),
      findsOneWidget,
    );
  });

  testWidgets('shows the waking line on the first request only', (
    WidgetTester tester,
  ) async {
    final _SlowService service = _SlowService();
    await tester.pumpWidget(FoodPriceApp(service: service));

    await _fillForm(tester);
    await tester.tap(find.text('Predict'));
    await tester.pump();

    expect(
      find.text('Waking the server, this can take up to a minute.'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    service.completer.complete(_success);
    await tester.pump();
    await tester.pump();
  });

  testWidgets('renders the success card and sends the schema payload', (
    WidgetTester tester,
  ) async {
    final _FakeService service = _FakeService(_success);
    await tester.pumpWidget(FoodPriceApp(service: service));

    await _fillForm(tester);
    await tester.tap(find.text('Predict'));
    await tester.pump();
    await tester.pump();

    expect(find.text('1,250 RWF per Kg'), findsOneWidget);
    expect(
      find.text('Typical for this product: 1,100 RWF (+14%)'),
      findsOneWidget,
    );
    expect(find.textContaining('2016 to 2017'), findsOneWidget);
    expect(service.lastBody, <String, Object?>{
      'product': 'Dry beans',
      'unit': 'Kg',
      'district': 'Gasabo',
      'ur': settingValues.first,
      'month': DateTime.now().month,
    });
  });

  testWidgets('fits a phone screen with no scrolling', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(FoodPriceApp(service: _FakeService(_success)));

    final SingleChildScrollView view = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    expect(view.physics, isA<NeverScrollableScrollPhysics>());
    expect(
      tester.getBottomLeft(find.byType(ResultCard)).dy,
      lessThan(2280 / 2.75),
    );
  });

  test('reads the 422 detail and names the field and the allowed range', () {
    expect(
      messageFromValidation(
        '{"detail":[{"type":"less_than_equal","loc":["body","month"],'
        '"msg":"Input should be less than or equal to 12","input":13,'
        '"ctx":{"le":12}}]}',
      ),
      'Month must be between $monthMin and $monthMax.',
    );
    expect(
      messageFromValidation(
        '{"detail":[{"type":"literal_error","loc":["body","product"],'
        '"msg":"Input should be ...","input":"Unicorn meat"}]}',
      ),
      'Product must be one of the ${productValues.length} values the model '
      'was trained on.',
    );
    expect(
      messageFromValidation(
        '{"detail":[{"type":"missing","loc":["body","district"],'
        '"msg":"Field required"}]}',
      ),
      'District is required.',
    );
    expect(
      messageFromValidation('{"detail":"The uploaded file is empty."}'),
      'The uploaded file is empty.',
    );
  });

  test('formats prices and percentages for the card', () {
    expect(formatThousands(1250), '1,250');
    expect(formatThousands(999), '999');
    expect(formatThousands(1234567), '1,234,567');
    expect(formatPercent(13.636), '+14%');
    expect(formatPercent(-2), '-2%');
    expect(formatPercent(0.2), '0%');
  });

  test('rejects a price outside the generated range', () {
    expect(
      () => parsePrediction(
        '{"predicted_price_rwf": 99999, "typical_price_rwf": 500,'
        '"difference_pct": 1, "product": "Dry beans", "unit": "Kg",'
        '"note": "x"}',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
