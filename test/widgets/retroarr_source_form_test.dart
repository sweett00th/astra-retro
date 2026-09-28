import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_eshop/features/sources/manual_source_add_screen.dart';
import 'package:retro_eshop/models/config/source.dart';
import 'package:retro_eshop/providers/app_providers.dart';
import 'package:retro_eshop/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/pump_helpers.dart';

void main() {
  testWidgets('RetroArr form masks key and supports controller text entry/back',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final storage = StorageService();
    await storage.init();
    await tester.pumpWidget(createTestAppWithProviders(
        const ManualSourceAddScreen(type: SourceType.retroarr),
        overrides: [storageServiceProvider.overrideWithValue(storage)]));
    await tester.pumpAndSettle();
    expect(find.text('Test Connection'), findsOneWidget);
    expect(find.text('API key'), findsOneWidget);
    final fields =
        tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.length, 3); // name, URL, key; no SMB/user/password fields
    expect(fields.last.obscureText, true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pump();
    expect(fields[1].focusNode!.hasFocus, true);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    await tester.pump();
    expect(fields[1].focusNode!.hasFocus, false);
    expect(find.byType(ManualSourceAddScreen), findsOneWidget);
  });
}
