import 'package:flutter_app/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('renders one field per model input', (WidgetTester tester) async {
    await tester.pumpWidget(const PredictorApp());

    expect(find.byType(TextField), findsNWidgets(fieldSpecs.length));
  });

  testWidgets('reports empty fields instead of calling the API', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const PredictorApp());

    await tester.ensureVisible(find.text('Predict'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Predict'));
    await tester.pump();

    expect(find.textContaining('is required.'), findsNWidgets(fieldSpecs.length));
  });
}
