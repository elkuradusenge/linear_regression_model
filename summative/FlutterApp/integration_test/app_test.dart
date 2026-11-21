import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_app/main.dart';

/// Keeps pumping until the finder matches, so a real HTTP call can finish.
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 90),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  fail('Timed out waiting for $finder');
}

Future<void> fillForm(
  WidgetTester tester, {
  required String product,
  required String unit,
  required String district,
}) async {
  final Finder fields = find.byType(TextField);
  await tester.enterText(fields.at(0), product);
  await tester.enterText(fields.at(1), unit);
  await tester.enterText(fields.at(3), district);
  await tester.pump();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a valid request returns a price from the running API', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FoodPriceApp());
    await tester.pump();

    await fillForm(
      tester,
      product: 'Dry beans',
      unit: 'Kg',
      district: 'Nyarugenge',
    );

    await tester.tap(find.text('Predict'));
    await tester.pump();

    expect(
      find.text('Waking the server, this can take up to a minute.'),
      findsOneWidget,
    );

    await pumpUntil(tester, find.textContaining('RWF per'));

    expect(find.textContaining('RWF per Kg'), findsWidgets);
    expect(find.textContaining('Typical for this product:'), findsOneWidget);
    expect(find.textContaining('2016 to 2017'), findsOneWidget);
    debugPrint('SUCCESS CARD: ${tester.widgetList<Text>(find.byType(Text)).map((Text t) => t.data).where((String? s) => s != null && s.contains('RWF')).join(' | ')}');
  });

  testWidgets('an unknown product is refused with a readable message', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FoodPriceApp());
    await tester.pump();

    await fillForm(
      tester,
      product: 'Unicorn meat',
      unit: 'Kg',
      district: 'Nyarugenge',
    );

    await tester.tap(find.text('Predict'));
    await tester.pump();

    expect(find.textContaining('must be one of the 97 values'), findsOneWidget);
    debugPrint('ERROR CARD: ${tester.widgetList<Text>(find.byType(Text)).map((Text t) => t.data).where((String? s) => s != null && s.contains('must be')).join(' | ')}');
  });

  testWidgets('month 13 is refused with the allowed range', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FoodPriceApp());
    await tester.pump();

    await fillForm(
      tester,
      product: 'Dry beans',
      unit: 'Kg',
      district: 'Nyarugenge',
    );
    await tester.enterText(find.byType(TextField).at(2), '13');
    await tester.tap(find.text('Predict'));
    await tester.pump();

    expect(find.text('Month must be between 1 and 12.'), findsOneWidget);
    debugPrint('RANGE CARD: Month must be between 1 and 12.');
  });
}
