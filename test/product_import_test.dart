import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moncommerce/product_import.dart';

List<int> workbook(List<List<CellValue?>> rows) {
  final excel = Excel.createExcel();
  final sheet = excel[excel.getDefaultSheet()!];
  for (final row in rows) {
    sheet.appendRow(row);
  }
  return excel.encode()!;
}

void main() {
  final headers = [
    'Nom du produit',
    'Prix de vente (FCFA)',
    'Stock',
    'Code-barres',
    'Prix d’achat',
  ].map(TextCellValue.new).toList();
  test('importer les prix, le stock et les codes avec zéros initiaux', () {
    final result = parseProductWorkbook(
      workbook([
        headers,
        [
          TextCellValue('Savon'),
          TextCellValue('1 500 FCFA'),
          const IntCellValue(5),
          TextCellValue('00123'),
          const IntCellValue(900),
        ],
      ]),
    );
    expect(result.issues, isEmpty);
    expect(result.products.single.barcode, '00123');
    expect(result.products.single.price, 1500);
    expect(result.products.single.purchasePrice, 900);
    expect(result.products.single.stock, 5);
  });
  test(
    'ignorer les lignes invalides et doublons sans écraser le catalogue',
    () {
      final result = parseProductWorkbook(
        workbook([
          headers,
          [
            TextCellValue('Existant'),
            const IntCellValue(1),
            const IntCellValue(1),
            TextCellValue('00123'),
          ],
          [
            TextCellValue('Nouveau'),
            const IntCellValue(100),
            const IntCellValue(3),
            TextCellValue('00999'),
          ],
          [
            TextCellValue('Doublon'),
            const IntCellValue(100),
            const IntCellValue(3),
            TextCellValue('00999'),
          ],
          [
            TextCellValue('Invalide'),
            const IntCellValue(-1),
            const IntCellValue(3),
          ],
          [
            TextCellValue('Formule'),
            FormulaCellValue('SUM(1,2)'),
            const IntCellValue(3),
          ],
        ]),
        existingBarcodes: ['00123'],
      );
      expect(result.products.single.name, 'Nouveau');
      expect(result.issues, hasLength(4));
    },
  );
  test('modèle compatible et prix d’achat facultatif', () {
    final excel = Excel.decodeBytes(productImportTemplate());
    final sheet = excel['Produits'];
    sheet.updateCell(CellIndex.indexByString('A2'), TextCellValue('Riz'));
    sheet.updateCell(CellIndex.indexByString('B2'), const IntCellValue(1000));
    sheet.updateCell(CellIndex.indexByString('D2'), const IntCellValue(4));
    sheet.updateCell(CellIndex.indexByString('E2'), TextCellValue('000456'));
    final result = parseProductWorkbook(excel.encode()!);
    expect(result.products, hasLength(1));
    expect(result.products.single.purchasePrice, isNull);
    expect(result.products.single.barcode, '000456');
  });
  test('fichier sans colonnes attendues rejeté', () {
    expect(
      () => parseProductWorkbook(
        workbook([
          [TextCellValue('Autre')],
        ]),
      ),
      throwsFormatException,
    );
  });
}
