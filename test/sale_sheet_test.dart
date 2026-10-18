import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moncommerce/main.dart';

void main() {
  Future<void> openSale(
    WidgetTester tester, {
    Size size = const Size(1366, 900),
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: SaleSheet(
            products: [
              Product(
                'Savon de Marseille grand format pour toute la famille',
                1500,
                2,
                Icons.inventory,
                barcode: '00123',
              ),
              Product(
                'Produit épuisé',
                100,
                0,
                Icons.inventory,
                barcode: '00999',
              ),
              Product('Doublon A', 100, 1, Icons.inventory, barcode: '777'),
              Product('Doublon B', 100, 1, Icons.inventory, barcode: '777'),
            ],
            onValidated: (_, _, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> scan(WidgetTester tester, String code) async {
    await tester.enterText(
      find.widgetWithText(TextField, 'Lecteur de code-barres USB'),
      code,
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'lecteur sans Entrée : ajout automatique unique et scans répétés',
    (tester) async {
      await openSale(tester);
      final field = find.widgetWithText(
        TextField,
        'Lecteur de code-barres USB',
      );
      await tester.enterText(field, '00123');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.textContaining('ajouté • quantité 1'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.textContaining('ajouté • quantité 1'), findsOneWidget);
      await tester.enterText(field, '00123');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.textContaining('ajouté • quantité 2'), findsOneWidget);
      await tester.enterText(field, '00123');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.textContaining('Stock insuffisant'), findsOneWidget);
    },
  );

  testWidgets(
    'scan dans le champ client : préserver le nom et ajouter au panier',
    (tester) async {
      await openSale(tester);
      final client = find.widgetWithText(TextField, 'Client (facultatif)');
      await tester.enterText(client, 'Awa');
      for (final key in [
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit3,
      ]) {
        await tester.sendKeyEvent(key, character: key.keyLabel);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.textContaining('ajouté • quantité 1'), findsOneWidget);
      expect(tester.widget<TextField>(client).controller!.text, 'Awa');
    },
  );

  testWidgets('USB : ajout, scans répétés, stock, code inconnu et doublons', (
    tester,
  ) async {
    await openSale(tester);
    await scan(tester, '00123');
    expect(find.textContaining('ajouté • quantité 1'), findsOneWidget);
    await scan(tester, '00123');
    expect(find.textContaining('ajouté • quantité 2'), findsOneWidget);
    await scan(tester, '00123');
    expect(find.textContaining('Stock insuffisant'), findsOneWidget);
    expect(find.text('3 000 FCFA'), findsOneWidget);
    await scan(tester, '00999');
    expect(find.text('Stock insuffisant : Produit épuisé'), findsOneWidget);
    await scan(tester, '00000');
    expect(find.text('Code inconnu : 00000'), findsOneWidget);
    await scan(tester, '777');
    expect(
      find.textContaining('Code attribué à plusieurs produits'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('USB : scan matériel après sortie du champ de saisie', (
    tester,
  ) async {
    await openSale(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    // Place focus on a sale control, as after keyboard navigation.
    Focus.of(tester.element(find.text('Nouvelle vente'))).requestFocus();
    await tester.pump();
    for (final key in [
      LogicalKeyboardKey.digit0,
      LogicalKeyboardKey.digit0,
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
    ]) {
      await tester.sendKeyEvent(key, character: key.keyLabel);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.textContaining('ajouté • quantité 1'), findsOneWidget);
  });

  for (final size in [
    const Size(1366, 900),
    const Size(1024, 900),
    const Size(390, 844),
  ]) {
    testWidgets('Cartes sans débordement à $size', (tester) async {
      await openSale(tester, size: size, scale: 1.3);
      expect(tester.takeException(), isNull);
    });
  }
}
