import 'package:excel/excel.dart';

class ImportedProduct {
  const ImportedProduct({
    required this.name,
    required this.price,
    required this.stock,
    this.purchasePrice,
    this.barcode = '',
  });
  final String name, barcode;
  final int price, stock;
  final int? purchasePrice;
}

List<int> exportProductWorkbook(Iterable<ImportedProduct> products) {
  final workbook = Excel.createExcel();
  workbook.rename(workbook.getDefaultSheet()!, 'Produits');
  final sheet = workbook['Produits'];
  sheet.appendRow(
    [
      'Nom du produit',
      'Prix de vente (FCFA)',
      'Prix d’achat (FCFA)',
      'Stock',
      'Code-barres (texte)',
    ].map(TextCellValue.new).toList(),
  );
  for (final product in products) {
    sheet.appendRow([
      TextCellValue(product.name),
      IntCellValue(product.price),
      product.purchasePrice == null
          ? null
          : IntCellValue(product.purchasePrice!),
      IntCellValue(product.stock),
      TextCellValue(product.barcode),
    ]);
  }
  for (var column = 0; column < 5; column++) {
    sheet.setColumnWidth(column, column == 0 ? 36 : 24);
    sheet
        .cell(CellIndex.indexByColumnRow(columnIndex: column, rowIndex: 0))
        .cellStyle = CellStyle(
      bold: true,
    );
  }
  return workbook.encode()!;
}

class ProductImportResult {
  const ProductImportResult(
    this.sheetName,
    this.products,
    this.issues,
    this.warnings,
  );
  final String sheetName;
  final List<ImportedProduct> products;
  final List<String> issues, warnings;
}

String _header(String value) => value
    .toLowerCase()
    .replaceAll(RegExp('[éèêë]'), 'e')
    .replaceAll(RegExp('[àâä]'), 'a')
    .replaceAll(RegExp('[îï]'), 'i')
    .replaceAll(RegExp('[ôö]'), 'o')
    .replaceAll(RegExp('[ùûü]'), 'u')
    .replaceAll('ç', 'c')
    .replaceAll(RegExp('[^a-z0-9]'), '');

const _aliases = {
  'name': ['nom', 'produit', 'nomduproduit', 'designation', 'article'],
  'price': [
    'prix',
    'prixfcfa',
    'prixdevente',
    'prixdeventefcfa',
    'prixventefcfa',
    'prixvente',
  ],
  'stock': ['stock', 'stockinitial', 'quantite', 'qte'],
  'purchase': [
    'prixdachat',
    'prixdachatfcfa',
    'prixachat',
    'prixachatfcfa',
    'coutunitaire',
  ],
  'barcode': ['codebarres', 'codebarre', 'codebarrestexte', 'barcode', 'ean'],
};

ProductImportResult parseProductWorkbook(
  List<int> bytes, {
  Iterable<String> existingNames = const [],
  Iterable<String> existingBarcodes = const [],
}) {
  final workbook = Excel.decodeBytes(bytes);
  final names = existingNames.map((n) => n.trim().toLowerCase()).toSet();
  final codes = existingBarcodes
      .where((c) => c.trim().isNotEmpty)
      .map((c) => c.trim())
      .toSet();
  for (final entry in workbook.tables.entries) {
    final rows = entry.value.rows;
    final headerIndex = rows.indexWhere(
      (row) => row.any((c) => c?.value?.toString().trim().isNotEmpty == true),
    );
    if (headerIndex < 0) continue;
    final columns = <String, int>{};
    for (var i = 0; i < rows[headerIndex].length; i++) {
      final header = _header(rows[headerIndex][i]?.value?.toString() ?? '');
      for (final alias in _aliases.entries) {
        if (alias.value.contains(header)) {
          if (columns.containsKey(alias.key))
            throw const FormatException(
              'Plusieurs colonnes portent le même nom.',
            );
          columns[alias.key] = i;
        }
      }
    }
    if (!['name', 'price', 'stock'].every(columns.containsKey)) continue;
    final products = <ImportedProduct>[];
    final issues = <String>[];
    final warnings = <String>[];
    if (rows.length - headerIndex > 10001)
      throw const FormatException('Import limité à 10 000 lignes par fichier.');
    for (var i = headerIndex + 1; i < rows.length; i++) {
      final row = rows[i];
      if (row.every(
        (cell) => cell?.value == null || cell!.value.toString().trim().isEmpty,
      ))
        continue;
      CellValue? value(String key) {
        final index = columns[key];
        return index == null || index >= row.length ? null : row[index]?.value;
      }

      try {
        final rawName = value('name');
        if (rawName is FormulaCellValue)
          throw const FormatException(
            'Remplacez la formule du nom par sa valeur.',
          );
        final name = rawName?.toString().trim() ?? '';
        if (name.isEmpty)
          throw const FormatException('Nom du produit manquant.');
        final price = _integer(value('price'), 'Prix de vente');
        final stock = _integer(value('stock'), 'Stock');
        final purchaseValue = value('purchase');
        final purchase =
            purchaseValue == null || purchaseValue.toString().trim().isEmpty
            ? null
            : _integer(purchaseValue, 'Prix d’achat');
        final rawCode = value('barcode');
        if (rawCode is FormulaCellValue)
          throw const FormatException(
            'Code-barres : remplacez la formule par du texte.',
          );
        String barcode = rawCode?.toString().trim() ?? '';
        if (rawCode is IntCellValue || rawCode is DoubleCellValue) {
          barcode = _integer(rawCode, 'Code-barres').toString();
          if (barcode.length > 15)
            throw const FormatException(
              'Code-barres trop long pour une cellule numérique : utilisez du texte.',
            );
          warnings.add(
            'Ligne ${i + 1} : code-barres numérique, vérifiez les éventuels zéros initiaux ($barcode).',
          );
        } else if (rawCode != null && rawCode is! TextCellValue) {
          throw const FormatException(
            'Code-barres : utilisez une cellule texte.',
          );
        }
        if (barcode.isNotEmpty
            ? codes.contains(barcode)
            : names.contains(name.toLowerCase())) {
          throw FormatException(
            'Doublon ignoré : $name${barcode.isEmpty ? "" : " ($barcode)"}.',
          );
        }
        products.add(
          ImportedProduct(
            name: name,
            price: price,
            stock: stock,
            purchasePrice: purchase,
            barcode: barcode,
          ),
        );
        names.add(name.toLowerCase());
        if (barcode.isNotEmpty) codes.add(barcode);
      } on FormatException catch (error) {
        issues.add('Ligne ${i + 1} : ${error.message}');
      }
    }
    return ProductImportResult(entry.key, products, issues, warnings);
  }
  throw const FormatException(
    'Colonnes requises : Nom du produit, Prix de vente, Stock. Colonnes facultatives : Prix d’achat, Code-barres.',
  );
}

int _integer(CellValue? value, String label) {
  if (value is IntCellValue && value.value >= 0) return value.value;
  if (value is DoubleCellValue &&
      value.value.isFinite &&
      value.value >= 0 &&
      value.value == value.value.roundToDouble())
    return value.value.toInt();
  if (value is TextCellValue) {
    final raw = value
        .toString()
        .trim()
        .replaceAll(RegExp(r'[\s\u00a0\u202f]'), '')
        .replaceAll(RegExp('FCFA', caseSensitive: false), '');
    if (RegExp(r'^\d+([.,]0+)?$').hasMatch(raw)) {
      final parsed = int.tryParse(raw.split(RegExp('[.,]')).first);
      if (parsed != null) return parsed;
    }
  }
  throw FormatException(
    '$label : saisissez un entier positif ou nul, sans formule.',
  );
}

List<int> productImportTemplate() {
  final workbook = Excel.createExcel();
  workbook.rename(workbook.getDefaultSheet()!, 'Produits');
  final sheet = workbook['Produits'];
  sheet.appendRow(
    [
      'Nom du produit',
      'Prix de vente (FCFA)',
      'Prix d’achat (FCFA)',
      'Stock',
      'Code-barres (texte)',
    ].map(TextCellValue.new).toList(),
  );
  for (var column = 0; column < 5; column++) {
    sheet.setColumnWidth(column, column == 0 ? 32 : 24);
    sheet
        .cell(CellIndex.indexByColumnRow(columnIndex: column, rowIndex: 0))
        .cellStyle = CellStyle(
      bold: true,
    );
  }
  for (var row = 1; row <= 1000; row++) {
    sheet
        .cell(CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row))
        .cellStyle = CellStyle(
      numberFormat: NumFormat.standard_49,
    );
  }
  final help = workbook['Instructions'];
  help.setColumnWidth(0, 100);
  for (final line in [
    'Remplissez la feuille Produits à partir de la ligne 2.',
    'Nom, prix de vente et stock sont obligatoires. Prix d’achat et code-barres sont facultatifs.',
    'Montants en FCFA entiers et quantités positives ou nulles.',
    'Conservez les codes-barres en texte, surtout les zéros initiaux.',
    'Les doublons sont ignorés. L’import ne modifie jamais les produits existants.',
  ]) {
    help.appendRow([TextCellValue(line)]);
  }
  return workbook.encode()!;
}
