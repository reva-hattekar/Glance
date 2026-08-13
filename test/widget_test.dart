import 'package:flutter_test/flutter_test.dart';
import 'package:smart_glasses_detection/main.dart';

void main() {
  testWidgets('GlanceApp smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const GlanceApp());

    // Verify that the dashboard title is displayed.
    expect(find.byType(DashboardScreen), findsOneWidget);
  });
}
