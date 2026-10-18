import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

const sharedShopKeys = [
  'shop_phone',
  'shop_address',
  'shop_city',
  'receipt_footer_message_v1',
  'commercial_documents_v1',
  'commercial_document_customers_v1',
  'commercial_document_header_image_v1',
  'commercial_document_footer_image_v1',
  'commercial_document_stamp_image_v1',
  'commercial_document_signature_image_v1',
  'commercial_document_template_v1',
  'suppliers_v1',
  'supplier_debts_v1',
];

Map<String, dynamic> readSharedShopPreferences(SharedPreferences prefs) => {
  for (final key in sharedShopKeys)
    if (prefs.getString(key) != null) key: prefs.getString(key),
};

Future<void> writeSharedShopPreferences(
  SharedPreferences prefs,
  Map<String, dynamic> values,
) async {
  for (final key in sharedShopKeys) {
    if (values[key] is String) {
      if (!await prefs.setString(key, values[key] as String))
        throw StateError('Enregistrement des paramètres impossible.');
    } else {
      await prefs.remove(key);
    }
  }
}

/// Legacy screens use global preference keys: swap their values when owners change.
Future<void> activateShopPreferences(
  SharedPreferences prefs,
  String userId, {
  String? legacyOwner,
}) async {
  final previousOwner = prefs.getString('shared_shop_owner_v1') ?? legacyOwner;
  if (previousOwner != userId) {
    final previous = readSharedShopPreferences(prefs);
    if (previous.isNotEmpty)
      await prefs.setString(
        'shared_shop_settings_${previousOwner ?? "unassigned_backup"}',
        jsonEncode(previous),
      );
    final stored = prefs.getString('shared_shop_settings_$userId');
    await writeSharedShopPreferences(
      prefs,
      stored == null
          ? {}
          : Map<String, dynamic>.from(jsonDecode(stored) as Map),
    );
  }
  await prefs.setString('shared_shop_owner_v1', userId);
}
